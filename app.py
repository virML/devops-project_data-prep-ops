"""DataPrepOps demonstration API: authenticated jobs backed by private S3 + SQS."""
from __future__ import annotations
import hmac
import io
import json
import os
import re
import time
import uuid
from pathlib import PurePath
import boto3
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import Depends, FastAPI, File, Header, HTTPException, Request, Response, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from cleaner import MAX_CSV_BYTES

app = FastAPI(title="DataPrepOps API (synthetic CSV data only)", version="2.0")
app.add_middleware(CORSMiddleware, allow_origins=[
    os.getenv("UI_ORIGIN", "http://localhost:8081"), "http://127.0.0.1:8081"
], allow_methods=["GET", "POST"], allow_headers=["X-Demo-API-Key", "Content-Type"])
REQUESTS = Counter("dataprepops_http_requests_total", "HTTP requests", ["method", "path", "status"])
SUBMITTED = Counter("dataprepops_jobs_submitted_total", "Jobs placed on SQS")
UPLOAD_LATENCY = Histogram("dataprepops_upload_seconds", "Job upload latency")
ID_RE = re.compile(r"^[0-9a-f]{32}$")

@app.middleware("http")
async def secure_headers_metrics(request: Request, call_next):
    response = await call_next(request)
    path = request.url.path
    if path.startswith("/api/jobs/"):
        path = "/api/jobs/{id}"
    elif path not in ("/healthz", "/metrics", "/api/jobs", "/api/health"):
        path = "other"
    REQUESTS.labels(request.method, path, str(response.status_code)).inc()
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    return response


def require_key(x_demo_api_key: str | None = Header(default=None)):
    expected = os.getenv("DATAPREPOPS_API_KEY", "")
    if not expected:
        raise HTTPException(503, "Server authentication not configured")
    if not x_demo_api_key or not hmac.compare_digest(expected, x_demo_api_key):
        raise HTTPException(401, "API key required or invalid")


def settings():
    region = os.getenv("AWS_REGION", "ap-south-1")
    bucket = os.getenv("S3_BUCKET", "")
    queue = os.getenv("SQS_QUEUE_URL", "")
    if not bucket or not queue:
        raise HTTPException(503, "AWS resources not configured")
    return region, bucket, queue


def s3_client(region):
    return boto3.client("s3", region_name=region)


def status_for(job_id: str):
    if not ID_RE.fullmatch(job_id):
        raise HTTPException(400, "Invalid job ID")
    region, bucket, _ = settings()
    try:
        obj = s3_client(region).get_object(Bucket=bucket, Key=f"jobs/{job_id}/status.json")
        return json.loads(obj["Body"].read())
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") in ("NoSuchKey", "404"):
            raise HTTPException(404, "Job not found") from exc
        raise HTTPException(503, "S3 read unavailable") from exc
    except (BotoCoreError, OSError) as exc:
        raise HTTPException(503, "S3 read unavailable") from exc


@app.get("/healthz")
def healthz():
    return {"status": "ok", "component": "api"}


@app.get("/api/health")
def api_health():
    return {"status": "ok", "project": "DataPrepOps"}


@app.get("/metrics", include_in_schema=False)
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/api/jobs", status_code=202, dependencies=[Depends(require_key)])
async def submit_csv(file: UploadFile = File(...)):
    with UPLOAD_LATENCY.time():
        filename = PurePath((file.filename or "").replace("\\", "/")).name[:100]
        if not filename.lower().endswith(".csv"):
            raise HTTPException(400, "Upload a .csv file")
        data = await file.read(MAX_CSV_BYTES + 1)
        if not data or len(data) > MAX_CSV_BYTES:
            raise HTTPException(413, "CSV must be nonempty and at most 5 MiB")
        try:
            content = data.decode("utf-8-sig")
        except UnicodeDecodeError as exc:
            raise HTTPException(400, "CSV must use UTF-8 encoding") from exc
        if "\x00" in content or "\n" not in content:
            raise HTTPException(400, "Invalid CSV content")
        region, bucket, queue = settings()
        job_id = uuid.uuid4().hex
        s3 = s3_client(region)
        prefix = f"jobs/{job_id}"
        status = {"job_id": job_id, "state": "queued", "file_name": filename, "submitted_at": int(time.time())}
        try:
            s3.put_object(Bucket=bucket, Key=f"{prefix}/raw.csv", Body=data, ContentType="text/csv")
            s3.put_object(Bucket=bucket, Key=f"{prefix}/status.json", Body=json.dumps(status).encode(), ContentType="application/json")
            boto3.client("sqs", region_name=region).send_message(
                QueueUrl=queue, MessageBody=json.dumps({"job_id": job_id, "simulate_seconds": 0})
            )
        except (ClientError, BotoCoreError, OSError) as exc:
            try:
                status.update(state="failed", error="Unable to enqueue job")
                s3.put_object(Bucket=bucket, Key=f"{prefix}/status.json", Body=json.dumps(status).encode())
            except Exception:
                pass
            raise HTTPException(503, "AWS processing services unavailable") from exc
        SUBMITTED.inc()
        return status


@app.get("/api/jobs/{job_id}", dependencies=[Depends(require_key)])
def job(job_id: str):
    return status_for(job_id)


@app.get("/api/jobs/{job_id}/download", dependencies=[Depends(require_key)])
def download(job_id: str):
    if status_for(job_id).get("state") != "complete":
        raise HTTPException(409, "Job not complete")
    region, bucket, _ = settings()
    try:
        obj = s3_client(region).get_object(Bucket=bucket, Key=f"jobs/{job_id}/cleaned.csv")
    except (ClientError, BotoCoreError) as exc:
        raise HTTPException(503, "Cleaned CSV unavailable") from exc
    return StreamingResponse(io.BytesIO(obj["Body"].read()), media_type="text/csv", headers={
        "Content-Disposition": f'attachment; filename="cleaned-{job_id[:8]}.csv"'
    })


@app.get("/api/jobs/{job_id}/report", dependencies=[Depends(require_key)])
def report(job_id: str):
    if status_for(job_id).get("state") != "complete":
        raise HTTPException(409, "Job not complete")
    region, bucket, _ = settings()
    try:
        obj = s3_client(region).get_object(Bucket=bucket, Key=f"jobs/{job_id}/report.json")
    except (ClientError, BotoCoreError) as exc:
        raise HTTPException(503, "Report unavailable") from exc
    return json.loads(obj["Body"].read())
