#!/usr/bin/env bash
# Simple, controlled demonstrations on the AWS control EC2 instance.
set -euo pipefail
cd "$(dirname "$0")/.."
command="${1:-help}"
case "$command" in
  load)
    # Up to 60 simulated CSV processing jobs, 25s each, to demonstrate ASG scaling.
    set -a; source /etc/dataprepops.env; set +a
    /opt/dataprepops-demo-venv/bin/python - <<'PY'
import boto3, json, os, time, uuid
s3=boto3.client('s3',region_name=os.environ['AWS_REGION'])
sqs=boto3.client('sqs',region_name=os.environ['AWS_REGION'])
bucket,queue=os.environ['S3_BUCKET'],os.environ['SQS_QUEUE_URL']
payload=b'patient_id,age,score\nA01,25,10\nA02,,20\nA02,,20\nA03,45,\n'
for i in range(60):
    key=uuid.uuid4().hex
    prefix='jobs/'+key
    s3.put_object(Bucket=bucket, Key=prefix+'/raw.csv', Body=payload)
    s3.put_object(Bucket=bucket, Key=prefix+'/status.json', Body=json.dumps({'job_id':key,'state':'queued','file_name':f'demo{i}.csv','submitted_at':int(time.time())}).encode())
    sqs.send_message(QueueUrl=queue,MessageBody=json.dumps({'job_id':key,'simulate_seconds':25}))
print('60 synthetic CSV jobs queued. Check AWS SQS, CloudWatch and Auto Scaling Activity.')
PY
    ;;
  rbac)
    k=(sudo -u jenkins -H kubectl -n dataprepops)
    "${k[@]}" create secret generic classroom-demo-token \
      --from-literal=demo="$(openssl rand -hex 12)" --dry-run=client -o yaml | \
      sudo -u jenkins -H kubectl apply -f -
    who=system:serviceaccount:dataprepops:dataprepops-frontend
    echo 'Expected YES to list Pods:'
    "${k[@]}" auth can-i list pods --as="$who"
    echo 'Expected NO to read Secrets:'
    "${k[@]}" auth can-i get secrets --as="$who"
    ;;
  alerts)
    echo 'Making five unauthenticated requests (expect HTTP 401).'
    for i in 1 2 3 4 5; do
      code="$(curl -s -o /dev/null -w '%{http_code}' \
        http://127.0.0.1:8082/api/jobs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
      echo "Request $i: HTTP $code"
      test "$code" = 401
    done
    echo 'View Prometheus /alerts after evaluation. To test API-down: docker stop dataprepops-api; later docker start dataprepops-api.'
    ;;
  rollback)
    sudo -u jenkins -H kubectl -n dataprepops patch svc dataprepops-frontend \
      -p '{"spec":{"selector":{"app":"dataprepops-ui","color":"blue"}}}'
    sudo systemctl restart dataprepops-frontend.service
    for n in $(seq 1 15); do
      if curl -fsS http://127.0.0.1:8081/version.js 2>/dev/null | grep -q blue; then
        echo 'Blue restored'; exit 0
      fi
      sleep 2
    done
    echo 'Rollback service selector changed, but HTTP verification failed' >&2; exit 1
    ;;
  status)
    bash scripts/setup.sh status
    ;;
  help|*)
    echo 'On EC2 run: bash scripts/demo.sh load|rbac|alerts|rollback|status'
    ;;
esac
