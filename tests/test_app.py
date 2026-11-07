"""Consolidated offline tests: API security, CSV cleaning, S3/SQS mocks and infrastructure."""
import io
import json
from pathlib import Path
import pandas as pd
import pytest
from fastapi.testclient import TestClient
import app as main
from app import app
from cleaner import clean_csv

ROOT = Path(__file__).resolve().parents[1]


# ---- test_api_health.py ----
def test_healthz_without_aws_credentials():
    response = TestClient(app).get('/healthz')
    assert response.status_code == 200
    assert response.json()['status'] == 'ok'


def test_reject_invalid_job_identifier(monkeypatch):
    monkeypatch.setenv('DATAPREPOPS_API_KEY', 'test-key')
    response = TestClient(app).get('/api/jobs/not-an-id', headers={'X-Demo-API-Key': 'test-key'})
    assert response.status_code == 400


# ---- test_cleaning.py ----
def test_missing_and_duplicates():
    raw = b'name,age,score\nAna,20,10\nAna,20,10\nBen,,30\nCal,40,\n'
    output, info = clean_csv(raw)
    result = pd.read_csv(io.BytesIO(output))
    assert len(result) == 3
    assert result.isna().sum().sum() == 0
    assert info['duplicates_removed'] == 1
    assert info['missing_cells_before'] == 2
    assert info['quality_score_after'] == 100.0


def test_all_missing_numeric_and_categorical():
    raw = b'name,age\nA,\n,\nC,\n'
    out, report = clean_csv(raw)
    assert pd.read_csv(io.BytesIO(out)).isna().sum().sum() == 0
    assert report['missing_cells_after'] == 0


def test_empty_rejected():
    with pytest.raises(ValueError):
        clean_csv(b'')


def test_oversize_rejected():
    with pytest.raises(ValueError):
        clean_csv(b'x' * (5 * 1024 * 1024 + 1))


def test_spreadsheet_formula_escaped_in_export():
    raw = b"name,age\n=1+2,20\nnormal,30\n"
    out, report = clean_csv(raw)
    assert b"'=1+2" in out
    assert report['spreadsheet_formula_cells_escaped'] == 1



class FakeS3:
    def __init__(self):
        self.objects = {}

    def put_object(self, *, Bucket, Key, Body, **kw):
        self.objects[(Bucket, Key)] = Body

    def get_object(self, *, Bucket, Key):
        return {"Body": io.BytesIO(self.objects[(Bucket, Key)])}


class FakeSQS:
    def __init__(self):
        self.messages = []

    def send_message(self, *, QueueUrl, MessageBody):
        self.messages.append(json.loads(MessageBody))


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("DATAPREPOPS_API_KEY", "demo-test-secret")
    return TestClient(app)


# ---- test_job_lifecycle.py ----
def test_submit_then_fetch_status(monkeypatch):
    s3, sqs = FakeS3(), FakeSQS()
    monkeypatch.setenv("DATAPREPOPS_API_KEY", "test-only")
    monkeypatch.setenv("AWS_REGION", "ap-south-1")
    monkeypatch.setenv("S3_BUCKET", "demo-bucket")
    monkeypatch.setenv("SQS_QUEUE_URL", "https://example.invalid/demo-queue")
    monkeypatch.setattr(main, "s3_client", lambda region: s3)
    monkeypatch.setattr(main.boto3, "client", lambda service, **kw: sqs if service == "sqs" else s3)
    client = TestClient(main.app)
    h = {"X-Demo-API-Key": "test-only"}
    result = client.post("/api/jobs", headers=h, files={"file": ("test.csv", b"name,age\nA,25\nB,\n", "text/csv")})
    assert result.status_code == 202
    job_id = result.json()["job_id"]
    assert sqs.messages == [{"job_id": job_id, "simulate_seconds": 0}]
    status = client.get(f"/api/jobs/{job_id}", headers=h)
    assert status.status_code == 200
    assert status.json()["state"] == "queued"
    assert s3.objects[("demo-bucket", f"jobs/{job_id}/raw.csv")].startswith(b"name,age")


def test_download_and_report_after_worker_completion(monkeypatch):
    s3 = FakeS3()
    job_id = "a" * 32
    monkeypatch.setenv("DATAPREPOPS_API_KEY", "test-only")
    monkeypatch.setenv("S3_BUCKET", "demo-bucket")
    monkeypatch.setenv("SQS_QUEUE_URL", "https://example.invalid/demo-queue")
    monkeypatch.setattr(main, "s3_client", lambda region: s3)
    s3.put_object(Bucket="demo-bucket", Key=f"jobs/{job_id}/status.json", Body=b'{"state":"complete"}')
    s3.put_object(Bucket="demo-bucket", Key=f"jobs/{job_id}/cleaned.csv", Body=b"age\n25\n")
    s3.put_object(Bucket="demo-bucket", Key=f"jobs/{job_id}/report.json", Body=b'{"cleaned_rows":1}')
    client = TestClient(main.app)
    headers = {"X-Demo-API-Key": "test-only"}
    downloaded = client.get(f"/api/jobs/{job_id}/download", headers=headers)
    assert downloaded.status_code == 200
    assert downloaded.content == b"age\n25\n"
    report = client.get(f"/api/jobs/{job_id}/report", headers=headers)
    assert report.status_code == 200
    assert report.json()["cleaned_rows"] == 1


# ---- test_repo_infrastructure.py ----
def test_security_tools_present_in_jenkins():
    pipeline = (ROOT / "Jenkinsfile").read_text()
    assert "SonarQube" in pipeline
    assert "Trivy" in pipeline
    assert "OWASP ZAP" in pipeline


def test_kubernetes_security_configured():
    text = (ROOT / "k8s/blue.yaml").read_text()
    assert "runAsNonRoot: true" in text
    assert "readOnlyRootFilesystem: true" in text
    assert "serviceAccountName: dataprepops-frontend" in text


def test_control_ssh_only():
    text = (ROOT / "terraform/main.tf").read_text()
    assert "admin_ssh" in text
    assert 'from_port = 22' in text
    assert "for_each          = local.ports" not in text


# ---- test_security.py ----
def test_missing_token_denied(client):
    assert client.get("/api/jobs/" + "a" * 32).status_code == 401


def test_wrong_token_denied(client):
    assert client.post("/api/jobs", headers={"X-Demo-API-Key": "invalid"}).status_code == 401


def test_health_is_public_and_has_security_headers(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.headers["X-Content-Type-Options"] == "nosniff"
    assert r.headers["X-Frame-Options"] == "DENY"


def test_filename_and_payload_validation(client):
    h = {"X-Demo-API-Key": "demo-test-secret"}
    assert client.post("/api/jobs", headers=h, files={"file": ("wrong.txt", b"a,b\n1,2")}).status_code == 400
    assert client.post("/api/jobs", headers=h, files={"file": ("test.csv", b"a\x00,b\n1,2")}).status_code == 400
    assert client.post("/api/jobs", headers=h, files={"file": ("test.csv", b"a,b\n1,\xff")}).status_code == 400


def test_invalid_job_id_rejected_before_aws(client):
    r = client.get("/api/jobs/not-valid", headers={"X-Demo-API-Key": "demo-test-secret"})
    assert r.status_code == 400


def test_cors_not_wildcard(client):
    r = client.options("/api/jobs", headers={"Origin": "https://attacker.example", "Access-Control-Request-Method": "POST"})
    assert r.headers.get("access-control-allow-origin") != "*"
    assert r.headers.get("access-control-allow-origin") != "https://attacker.example"


def test_metrics_count_unauthorized(client):
    client.get("/api/jobs/" + "a" * 32)
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "dataprepops_http_requests_total" in r.text
