# DataPrepOps — Simplified Cloud + DevOps + DevSecOps College Project

**Purpose:** A small four-module CSV cleaning web application demonstrating Git, Terraform, Ansible, Jenkins CI/CD, Docker, Kubernetes, monitoring, and the security tools from VLE-9.

**Status:** source code and local tests are provided. Terraform, AWS, Docker images, Jenkins, security scans, Kubernetes deployment, scaling, and alerts must **still be executed and verified on your machines**. A passing GitHub Actions test is not proof that AWS deployment is complete.

**Safety/cost:** Use **synthetic/public CSV data only**. This is not a production-ready healthcare system. AWS provisions three EC2 instances (plus a possible fourth on scale-out), EBS, public IPv4, S3, ECR, SQS, CloudWatch and SNS; they may cost money. The course rule on 3 EC2 instances in one AWS account still applies: if this is a group project, get supervisor permission first. Set an AWS Budget, deploy for the demo, and **run Terraform destroy afterward**.

## 1. Four simple application modules

1. **Upload:** browser submits a UTF-8 CSV up to 5 MiB; FastAPI saves it privately to S3 and sends its job ID to SQS.
2. **Clean:** two autoscaled EC2 Docker workers remove duplicates and fill missing values; numeric outliers are counted, not deleted.
3. **Report:** before/after row counts, missing values and a quality score.
4. **Download:** browser polls the job status and downloads the cleaned CSV.

Core files: `app.py` (API), `cleaner.py` (CSV algorithm), `worker.py` (SQS worker), `index.html` (web page). There is no database, ML model training, or complex UI.

## 2. How every major subject is demonstrated

| Subject / VLE | File(s) | Demonstration |
|---|---|---|
| Git/GitHub | this repository, `.github/workflows/tests.yml` | commit, branch and merge; GitHub Actions runs tests |
| VLE-4: Terraform/AWS | `terraform/` | VPC, two subnets, IAM, S3, SQS, ECR, EC2, Auto Scaling, CloudWatch |
| VLE-4/5: Ansible | `ansible/setup.yml`, `scripts/setup.sh` | automated installation on EC2 |
| VLE-6: Jenkins/Maven | `Jenkinsfile`, `java-validator/` | pipeline and basic Java CSV-header validation |
| VLE-7: Docker/Kubernetes | `Dockerfile*`, `k8s/` | build two image types, deploy Blue and Green frontends |
| VLE-7: Monitoring | `monitoring/` | Prometheus, Grafana, Alertmanager alerts |
| VLE-8: Blue-Green | `Jenkinsfile`, `scripts/demo.sh rollback` | approve switch to Green and roll back to Blue |
| VLE-9: SonarQube | `Jenkinsfile` | static analysis with quality gate |
| VLE-9: Trivy | `Jenkinsfile` | scan application and UI Docker images |
| VLE-9: OWASP ZAP | `Jenkinsfile` | baseline DAST scan of `/docs` |
| VLE-9: security | `app.py`, `k8s/namespace-rbac.yaml` | API key, input validation, non-root images, RBAC, runtime Secret |
| Cloud scaling | `terraform/main.tf`, `scripts/demo.sh load` | CloudWatch SQS alarm scales ASG from 2 to 3 workers |

**Beyond the specified running-tool list:** Docker Swarm, Gradle and Artifactory are syllabus alternatives, not additional deployed stacks in this small project. Discuss their differences in your viva if asked. Trivy uses *report-only* mode; its output is not proof of vulnerability remediation. ZAP's baseline scan is passive. SonarQube's passing quality gate is not a security certification.

## 3. Simple architecture

```text
Your Mac -- SSH (port 22, tunnels) --> AWS EC2 control server
  GitHub --> Jenkins --> tests, Maven, SonarQube, Docker, Trivy, OWASP ZAP
                           |                    |
                           v                    v
                    Kubernetes Blue/Green    ECR worker image
                           |                    |
                       Frontend           EC2 ASG: 2 workers (max 3)
                           |                    |
                       FastAPI -> S3 raw/clean + SQS queue

Monitoring: Prometheus + Grafana + Alertmanager on control EC2
AWS: Terraform + Ansible + IAM + CloudWatch alarms + Auto Scaling
```

The Kubernetes cluster is **single-node Minikube on the control EC2**, not three Kubernetes nodes. The other EC2 instances run the **background CSV workers in Docker**. Frontend and API consoles bind to loopback on EC2 and are reached through SSH tunnels. The worker instances have **no inbound security-group rules** but have outbound network access, and public IPv4 for lab simplicity; a real production architecture would use private subnets/VPC endpoints. This project is deliberately classroom-scale.

## 4. Upload to GitHub

Extract the ZIP, open `dataprepops/`, then upload **the files and folders inside that directory** to the root of a new GitHub repository; do not upload the ZIP itself or nest the whole project under `dataprepops/`.

Make sure hidden `.github/` and `.gitignore` survive. Alternatively, from the extracted folder:

```bash
git init
git branch -M main
git add .
git commit -m "Initial simplified DataPrepOps project"
git remote add origin https://github.com/YOUR-USERNAME/YOUR-NEW-REPO.git
git push -u origin main
```

Only push into a **new empty repository** with those commands. Do not force-push over a repository containing earlier work. The `.gitignore` blocks private `.pem`, `.env`, Terraform state, real `.tfvars`, and reports. Never commit credentials, token values or real patient data.

After the first push: GitHub **Actions → Python CI** must show the tests passing.

## 5. First run local Python tests on Mac

```bash
cd /path/to/cloned-or-extracted/dataprepops
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python -m pytest -q
# Expected in prepared version: 19 tests pass
```

These tests use fake S3/SQS clients; **no AWS resources are created by pytest**.

## 6. Deploy AWS infrastructure from Mac (Terraform)

Required: AWS CLI, Terraform (>=1.5), Ansible, an AWS account, a budget alert, an EC2 key pair created in the same region, and an SSH `.pem` private key already on your Mac.

```bash
aws sts get-caller-identity
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
curl -4fsS https://checkip.amazonaws.com   # use this public IPv4 address + /32
```

Edit `terraform/terraform.tfvars`:
- `aws_region`: for example `ap-south-1` (Mumbai).
- `key_name`: existing **EC2 key pair name**, not the `.pem` filename.
- `admin_cidr`: **your current public IPv4** plus `/32` (never `0.0.0.0/0`).
- `control_instance_type`: the example `m7i-flex.large` has 8 GiB; a **16-GiB** instance may be required for Jenkins + SonarQube + Minikube. Check current regional offerings, AWS quota and cost.
- `worker_instance_type`: example `t3.micro` (verify regional/quota availability).
- `alert_email`: optional CloudWatch SNS notifications. Confirm the SNS subscription email if used.

```bash
terraform -chdir=terraform init
terraform -chdir=terraform fmt
terraform -chdir=terraform validate
terraform -chdir=terraform plan
# Inspect the resource count and charges before proceeding.
terraform -chdir=terraform apply
terraform -chdir=terraform output
```

Terraform creates an EC2 control server plus an ASG with **two worker EC2 instances** (maximum three), and the S3/SQS/ECR resources. The workers will retry image pull until you publish the Docker image to ECR; this is expected on initial bootstrap. Terraform state is a **local private file**; keep it until after `destroy`.

## 7. Configure the AWS control server using Ansible

From your Mac, in the project directory:

```bash
export SSH_KEY="$HOME/path/to/YOUR-EXISTING-KEY.pem"
chmod 400 "$SSH_KEY"
bash scripts/setup.sh provision
```

Ansible installs Docker and Docker Compose, Git, Java/Maven, Jenkins, AWS CLI, kubectl and Minikube; configures a locked-down frontend forwarding service and a non-secret `/etc/dataprepops.env`. If Ansible package installation fails, check the Ubuntu universe repository and apt logs. Jenkins requires Java 21. An 8-GiB EC2 may be tight on memory with the tools running simultaneously.

SSH to EC2 to continue the application setup. In **Mac Terminal 1**:

```bash
ssh -i "$SSH_KEY" ubuntu@"$(terraform -chdir=terraform output -raw control_public_ip)"
```

In the EC2 session, clone your new GitHub repository (replace the URL):

```bash
git clone https://github.com/YOUR-USERNAME/YOUR-NEW-REPO.git
cd YOUR-NEW-REPO
bash scripts/setup.sh blue   # initial Blue Kubernetes frontend
bash scripts/setup.sh sonar  # SonarQube on loopback:9000
read -rsp 'Grafana admin password: ' GRAFANA_ADMIN_PASSWORD; echo
export GRAFANA_ADMIN_PASSWORD
bash scripts/setup.sh monitor
```

Open **Mac Terminal 2**, inside your local clone/extracted project, and leave it running:

```bash
export SSH_KEY="$HOME/path/to/YOUR-EXISTING-KEY.pem"
bash scripts/setup.sh tunnel
```

Access from your Mac browser: Jenkins **http://localhost:8080**, UI **http://localhost:8081**, API **http://localhost:8082/docs**, SonarQube **http://localhost:9000**, Grafana **http://localhost:3000**, Prometheus **http://localhost:9090**. Don't open these ports in the AWS security group.

## 8. Jenkins + SonarQube first-time setup (browser)

1. On the EC2 terminal, run `sudo cat /var/lib/jenkins/secrets/initialAdminPassword` and finish the Jenkins wizard at `localhost:8080`. Install suggested plugins plus Git/Pipeline/Credentials as needed.
2. In SonarQube at `localhost:9000`, complete first login and change default credentials. Create project key **`dataprepops`** and a project-scoped analysis token.
3. Jenkins → Credentials: create two **Secret text** entries:
   - ID `dataprepops-sonar-token`: the SonarQube analysis token.
   - ID `dataprepops-api-key`: a generated, memorable **demo** API key. This must **not** be in Git.
4. Jenkins → New Item → **Pipeline** → "Pipeline script from SCM" → Git → your **new GitHub repository URL** → branch `*/main` → `Jenkinsfile`.
5. Build Now. Watch stages: checkout → 19 tests → Maven → SonarQube gate → build two non-root Docker images → Trivy reports → ECR publish → API start → Kubernetes Blue/Green → OWASP ZAP → approval → verified Green switch.
6. Press **Switch** at the manual Jenkins approval when you are ready to change to Green. Review the scan reports in Jenkins artifacts.

If Jenkins lacks enough memory, disk space, permissions or a required plugin, fix the specific error before rerunning. GitHub Actions passing does not imply Jenkins will pass automatically. A Docker permission change often requires **a new login/service restart**, already handled by Ansible for Jenkins.

After a successful build, EC2 ASG workers can pull the ECR worker image and process SQS messages. They are separate EC2 machines; the container uses the **same Python image** with `python worker.py` as its command instead of the default API server command.

For an **optional pre-Jenkins smoke test** of the API, on EC2:

```bash
read -rsp 'Demo API key: ' DATAPREPOPS_API_KEY; echo
export DATAPREPOPS_API_KEY
bash scripts/setup.sh api
bash scripts/setup.sh worker
```

If doing this manual test, give Jenkins the **same demo API key** if you want the browser credential to remain consistent.

## 9. Monitoring, alerting and dashboard

Prometheus collects the API's `/metrics` endpoint. Grafana and Alertmanager are started via `docker compose`. In Grafana → Connections → Data sources → add **Prometheus** with URL `http://127.0.0.1:9090` and save. Make a simple dashboard panel with PromQL: `up{job="dataprepops-api"}`. A value of **1** means the API scrape target is up.

In the EC2 terminal:

```bash
bash scripts/demo.sh alerts
```

Then open `http://localhost:9090/alerts` to see the unauthorized-access alert (allow at least 2–3 metric evaluation intervals). To demonstrate API-down alert: `docker stop dataprepops-api`; wait for the alert's `for: 45s` duration, then **restore immediately** with `docker start dataprepops-api`. This is a demo, not a managed monitoring service for production. Alertmanager uses a notification-free receiver; AWS CloudWatch/SNS provides optional email alerting.

## 10. Security, auto scaling, rollback

On EC2:

```bash
bash scripts/demo.sh rbac
# Expected: service account can list Pods, cannot get Secrets.

bash scripts/demo.sh load
# Sends 60 synthetic CSV jobs at 25 seconds each. Check the AWS SQS backlog,
# CloudWatch alarm and EC2 Auto Scaling activity as min=2 scales to max=3.

bash scripts/demo.sh rollback
# Kubernetes Service points to Blue again; UI version label confirms it.

bash scripts/setup.sh status
```

The Kubernetes Secret created during `rbac` is a **dummy classroom-only Secret** generated at runtime, never committed. For VLE-9 evidence, show Jenkins SonarQube quality gate, non-root image check, Trivy CVE report, ZAP HTML report, the two `kubectl auth can-i` results, 401 API behavior, Prometheus/Grafana, and Green/Blue switch. Do **not** claim Trivy findings are fixed unless you actually remediate and rescan.

## 11. Five-minute professor demo and screenshots

1. GitHub: explain version control and green Python CI.
2. Terraform AWS Console: show VPC, one control EC2 and two worker EC2 in the ASG; CloudWatch queue alarms.
3. Ansible recap: show automated installation, then Docker containers (`docker ps`).
4. UI: upload `sample.csv`, show the quality report, download cleaned CSV.
5. Jenkins: show the green build, Maven, SonarQube, Trivy report, OWASP ZAP report.
6. Kubernetes: `kubectl -n dataprepops get deployments,pods,svc` and Blue/Green selector; RBAC Secret demo.
7. Grafana/Prometheus: API scrape value and an alert. AWS Console: show Auto Scaling if the load test triggered it.
8. Demonstrate `bash scripts/demo.sh rollback` returning to Blue.

**Important:** Save screenshots from your actual deployment. Don't invent CloudWatch scaling activity, scanner results or Jenkins success. If some stage fails, say so and show the attempted step and diagnosis.

## 12. Clean up AWS to avoid charges

Save project evidence first. On your Mac:

```bash
terraform -chdir=terraform destroy
```

The classroom S3 bucket has `force_destroy = true`; **destroy deletes all processed demo CSV files**. Confirm EC2, Auto Scaling, EBS, Elastic/Public IP charges, S3, ECR, SNS and CloudWatch in the AWS console afterward. AWS resources are **not** removed merely by stopping Jenkins. Do not lose local Terraform state until the resources are destroyed.

### Basic troubleshooting

- **SSH fails:** public IP changed, private key permissions, or your `admin_cidr` no longer matches your current network. Update tfvars and re-apply Terraform, instead of opening port 22 worldwide.
- **Control is short on memory:** SonarQube + Jenkins + Minikube + Grafana can overload 8 GiB. Review CloudWatch, change EC2 instance size only after understanding cost, or temporarily stop nonessential containers during configuration.
- **API S3/SQS failures:** check `/etc/dataprepops.env`, IAM instance role, AWS region and worker service logs (`journalctl -u dataprepops-worker-bootstrap.service`).
- **Worker container missing:** expected before ECR publish; first publish `:latest`, then wait for bootstrap retry. Check AWS ECR and worker EC2 systemd logs if it does not start.
- **Jenkins fails:** look at the exact stage, credentials IDs, SonarQube status, Docker permissions, Minikube image loading and kubectl context. Check `sudo journalctl -u jenkins -n 80` on EC2.
- **Grafana cannot see Prometheus:** both use host network and loopback; the Grafana data source URL must be `http://127.0.0.1:9090`.
- **Blue/Green UI appears stale:** the port-forward service is attached to a Pod and must be restarted after a Service selector change. The Jenkinsfile and `demo.sh` do this.
- **ZIP files in GitHub:** upload the extracted project contents, not the ZIP file as-is.
