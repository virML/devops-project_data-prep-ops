pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds(); skipDefaultCheckout(true) }
  stages {
    stage('Git checkout') {
      steps { checkout scm }
    }
    stage('Python tests') {
      steps { sh '''#!/bin/bash
        set -euo pipefail
        python3 -m venv .jenkins-venv
        .jenkins-venv/bin/python -m pip install -q -r requirements.txt
        .jenkins-venv/bin/python -m pytest -q
      ''' }
    }
    stage('Maven validation') {
      steps { sh '''#!/bin/bash
        set -euo pipefail
        mvn -B -f java-validator/pom.xml package
        java -cp java-validator/target/classes com.dataprepops.HeaderValidator sample.csv
      ''' }
    }
    stage('SonarQube SAST and quality gate') {
      steps {
        withCredentials([string(credentialsId: 'dataprepops-sonar-token', variable: 'SONAR_TOKEN')]) {
          sh '''#!/bin/bash
            set -euo pipefail
            curl -fsS http://127.0.0.1:9000/api/system/status | grep -q '"UP"'
            docker run --rm --network host \
              -v "$PWD:/usr/src:rw" -w /usr/src \
              -e SONAR_HOST_URL=http://127.0.0.1:9000 -e SONAR_TOKEN \
              -e SONAR_USER_HOME=/tmp/sonar-cache \
              sonarsource/sonar-scanner-cli:latest \
              -Dsonar.projectKey=dataprepops \
              -Dsonar.sources=app.py,cleaner.py,worker.py \
              -Dsonar.tests=tests \
              -Dsonar.python.version=3.12 \
              -Dsonar.qualitygate.wait=true
          '''
        }
      }
    }
    stage('Build non-root Docker images') {
      steps { sh '''#!/bin/bash
        set -euo pipefail
        docker build -f Dockerfile -t "dataprepops-app:build-${BUILD_NUMBER}" .
        docker build -f Dockerfile.frontend --build-arg VERSION=blue -t dataprepops-ui:blue .
        docker build -f Dockerfile.frontend --build-arg VERSION="green-${BUILD_NUMBER}" \
          -t "dataprepops-ui:green-${BUILD_NUMBER}" .
        for img in "dataprepops-app:build-${BUILD_NUMBER}" "dataprepops-ui:green-${BUILD_NUMBER}"; do
          test "$(docker inspect --format '{{.Config.User}}' "$img")" = '10001:10001'
        done
      ''' }
    }
    stage('Trivy container security scans') {
      steps { sh '''#!/bin/bash
        set -euo pipefail
        mkdir -p reports
        for part in app ui; do
          if [ "$part" = app ]; then img="dataprepops-app:build-${BUILD_NUMBER}"; else img="dataprepops-ui:green-${BUILD_NUMBER}"; fi
          docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
            -v "$PWD/reports:/reports:rw" aquasec/trivy:0.76.0 image \
            --scanners vuln --severity HIGH,CRITICAL --exit-code 0 \
            --format table --output "/reports/trivy-$part.txt" "$img"
        done
        echo 'Trivy is report-only: review the detected CVEs in the archived reports.'
      ''' }
    }
    stage('Push worker image to AWS ECR') {
      steps { sh '''#!/bin/bash
        set -euo pipefail
        set -a; source /etc/dataprepops.env; set +a
        aws ecr get-login-password --region "$AWS_REGION" | \
          docker login --username AWS --password-stdin "${ECR_WORKER_URI%%/*}"
        docker tag "dataprepops-app:build-${BUILD_NUMBER}" "$ECR_WORKER_URI:latest"
        docker push "$ECR_WORKER_URI:latest"
      ''' }
    }
    stage('Start authenticated API') {
      steps {
        withCredentials([string(credentialsId: 'dataprepops-api-key', variable: 'DATAPREPOPS_API_KEY')]) {
          sh '''#!/bin/bash
            set -euo pipefail
            set -a; source /etc/dataprepops.env; set +a
            docker rm -f dataprepops-api >/dev/null 2>&1 || true
            docker run -d --name dataprepops-api --restart unless-stopped \
              -p 127.0.0.1:8082:8082 \
              -e AWS_REGION -e S3_BUCKET -e SQS_QUEUE_URL -e UI_ORIGIN \
              -e DATAPREPOPS_API_KEY "dataprepops-app:build-${BUILD_NUMBER}"
            curl --retry 30 --retry-delay 2 --retry-all-errors --max-time 5 -fsS http://127.0.0.1:8082/healthz
          '''
        }
      }
    }
    stage('Kubernetes Blue and Green deployment') {
      steps { sh '''#!/bin/bash
        set -euo pipefail
        minikube image load dataprepops-ui:blue
        kubectl apply -f k8s/namespace-rbac.yaml
        kubectl apply -f k8s/blue.yaml
        kubectl apply -f k8s/service.yaml
        kubectl -n dataprepops rollout status deployment/dataprepops-blue --timeout=180s
        sudo -n /usr/bin/systemctl restart dataprepops-frontend.service
        minikube image load "dataprepops-ui:green-${BUILD_NUMBER}"
        sed "s/__BUILD_TAG__/green-${BUILD_NUMBER}/" k8s/green.yaml | kubectl apply -f -
        kubectl -n dataprepops rollout status deployment/dataprepops-green --timeout=180s
        test "$(kubectl -n dataprepops get deployment dataprepops-green -o jsonpath='{.status.readyReplicas}')" = 2
      ''' }
    }
    stage('OWASP ZAP passive DAST') {
      steps { sh '''#!/bin/bash
        set -euo pipefail
        curl -fsS http://127.0.0.1:8082/docs >/dev/null
        mkdir -p reports
        chmod 1777 reports  # temporary shared output directory for ZAP demo container
        docker run --rm --network host -v "$PWD/reports:/zap/wrk:rw" \
          ghcr.io/zaproxy/zaproxy:stable zap-baseline.py \
          -t http://127.0.0.1:8082/docs -m 1 -r zap-report.html -J zap-report.json -I
      ''' }
    }
    stage('Approve Green') {
      steps { input message: 'SAST, Trivy, ZAP and Kubernetes checks finished. Switch traffic to Green?', ok: 'Switch' }
    }
    stage('Switch traffic to Green') {
      steps { sh '''#!/bin/bash
        set -euo pipefail
        kubectl -n dataprepops patch svc dataprepops-frontend \
          -p '{"spec":{"selector":{"app":"dataprepops-ui","color":"green"}}}'
        sudo -n /usr/bin/systemctl restart dataprepops-frontend.service
        for n in $(seq 1 20); do
          if curl -fsS http://127.0.0.1:8081/version.js 2>/dev/null | grep -q "green-${BUILD_NUMBER}"; then
            echo "Green version green-${BUILD_NUMBER} live"; exit 0
          fi
          sleep 2
        done
        echo 'Green traffic switch was not verified' >&2; exit 1
      ''' }
    }
  }
  post {
    always { archiveArtifacts artifacts: 'reports/*', allowEmptyArchive: true }
    success { echo 'DataPrepOps DevSecOps pipeline finished. Blue retained for rollback.' }
    failure { echo 'Check the failed Jenkins stage and the archived scan reports.' }
  }
}
