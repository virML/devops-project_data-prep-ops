#!/usr/bin/env bash
# One setup script for the laptop and for the AWS control EC2 instance.
set -euo pipefail
cd "$(dirname "$0")/.."
command="${1:-help}"
tf() { terraform -chdir=terraform "$@"; }

case "$command" in
  provision) # Mac: Terraform must already have been applied.
    : "${SSH_KEY:?Export SSH_KEY=/absolute/path/to/your-ec2-private.pem}"
    ip="$(tf output -raw control_public_ip)"
    ansible-playbook -i "${ip}," -u ubuntu --private-key "$SSH_KEY" ansible/setup.yml \
      -e "aws_region=$(tf output -raw aws_region)" \
      -e "s3_bucket=$(tf output -raw s3_bucket)" \
      -e "sqs_queue_url=$(tf output -raw sqs_queue_url)" \
      -e "ecr_worker_uri=$(tf output -raw ecr_worker_uri)"
    echo 'Control configured. Use setup.sh tunnel from your Mac.'
    ;;
  tunnel) # Mac: keep this terminal open; consoles never exposed in AWS security group.
    : "${SSH_KEY:?Export SSH_KEY=/absolute/path/to/your-ec2-private.pem}"
    ip="$(tf output -raw control_public_ip)"
    exec ssh -o ExitOnForwardFailure=yes -i "$SSH_KEY" -N \
      -L 8080:127.0.0.1:8080 -L 8081:127.0.0.1:8081 \
      -L 8082:127.0.0.1:8082 -L 9000:127.0.0.1:9000 \
      -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 \
      -L 9093:127.0.0.1:9093 "ubuntu@$ip"
    ;;
  sonar) # EC2: start SonarQube, finish setup at http://localhost:9000 through SSH.
    sudo sysctl -w vm.max_map_count=524288 >/dev/null
    echo vm.max_map_count=524288 | sudo tee /etc/sysctl.d/90-dataprepops-sonar.conf >/dev/null
    docker volume create dataprepops-sonar-data >/dev/null
    docker rm -f dataprepops-sonar >/dev/null 2>&1 || true
    docker run -d --name dataprepops-sonar --restart unless-stopped \
      -p 127.0.0.1:9000:9000 \
      -e SONAR_WEB_JAVAOPTS='-Xms256m -Xmx512m' \
      -e SONAR_CE_JAVAOPTS='-Xms256m -Xmx512m' \
      -e SONAR_SEARCH_JAVAOPTS='-Xms512m -Xmx512m' \
      -v dataprepops-sonar-data:/opt/sonarqube/data sonarqube:community
    echo 'SonarQube started; finish first login/project creation via SSH tunnel.'
    ;;
  monitor) # EC2: Prometheus, Grafana, Alertmanager share the host loopback network.
    : "${GRAFANA_ADMIN_PASSWORD:?Export GRAFANA_ADMIN_PASSWORD without saving it in Git}"
    docker compose -f monitoring/docker-compose.yml up -d
    echo 'Use localhost:3000 Grafana, :9090 Prometheus, :9093 Alertmanager through the tunnel.'
    ;;
  blue) # EC2: initial Kubernetes Blue frontend; Jenkins also performs this in CI/CD.
    docker build -f Dockerfile.frontend --build-arg VERSION=blue -t dataprepops-ui:blue .
    sudo -u jenkins -H minikube image load dataprepops-ui:blue
    sudo -u jenkins -H kubectl apply -f k8s/namespace-rbac.yaml
    sudo -u jenkins -H kubectl apply -f k8s/blue.yaml
    sudo -u jenkins -H kubectl apply -f k8s/service.yaml
    sudo -u jenkins -H kubectl -n dataprepops rollout status deployment/dataprepops-blue --timeout=180s
    sudo systemctl enable --now dataprepops-frontend.service
    echo 'Blue UI: http://localhost:8081 through SSH tunnel.'
    ;;
  api) # EC2: optional manual API smoke test; Jenkins deploys API automatically as well.
    set -a; source /etc/dataprepops.env; set +a
    : "${DATAPREPOPS_API_KEY:?Export a demo API key (never commit it)}"
    docker build -f Dockerfile -t dataprepops-app:manual .
    docker rm -f dataprepops-api >/dev/null 2>&1 || true
    docker run -d --name dataprepops-api --restart unless-stopped \
      -p 127.0.0.1:8082:8082 \
      -e AWS_REGION -e S3_BUCKET -e SQS_QUEUE_URL -e UI_ORIGIN \
      -e DATAPREPOPS_API_KEY dataprepops-app:manual
    curl --retry 20 --retry-delay 2 --retry-connrefused -fsS http://127.0.0.1:8082/healthz
    echo
    ;;
  worker) # EC2: publish image to ECR so ASG workers can pull :latest.
    set -a; source /etc/dataprepops.env; set +a
    docker build -f Dockerfile -t dataprepops-app:manual .
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS \
      --password-stdin "${ECR_WORKER_URI%%/*}"
    docker tag dataprepops-app:manual "$ECR_WORKER_URI:latest"
    docker push "$ECR_WORKER_URI:latest"
    echo 'Worker published. ASG instances retry ECR until it becomes available.'
    ;;
  status) # EC2
    set -a; source /etc/dataprepops.env; set +a
    curl -fsS http://127.0.0.1:8082/healthz; echo
    docker ps --format 'table {{.Names}}\t{{.Status}}'
    sudo -u jenkins -H kubectl -n dataprepops get deployment,pod,svc
    aws sqs get-queue-attributes --region "$AWS_REGION" --queue-url "$SQS_QUEUE_URL" \
      --attribute-names ApproximateNumberOfMessages
    ;;
  help|*)
    cat <<'HELP'
Usage:
 On Mac:  SSH_KEY=... bash scripts/setup.sh provision|tunnel
 On EC2:  bash scripts/setup.sh sonar|monitor|blue|api|worker|status
           (monitor needs GRAFANA_ADMIN_PASSWORD, api needs DATAPREPOPS_API_KEY)
 First apply Terraform and follow README.md step-by-step.
HELP
    ;;
esac
