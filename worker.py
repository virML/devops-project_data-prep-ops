"""Simple, retryable SQS worker with S3 output and visible job state."""
import json
import logging
import os
import time
import boto3
from cleaner import clean_csv

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger('worker')
REGION = os.environ.get('AWS_REGION', 'us-east-1')
BUCKET = os.environ['S3_BUCKET']
QUEUE = os.environ['SQS_QUEUE_URL']
s3 = boto3.client('s3', region_name=REGION)
sqs = boto3.client('sqs', region_name=REGION)


def put_json(key, obj):
    s3.put_object(Bucket=BUCKET, Key=key, Body=json.dumps(obj).encode(), ContentType='application/json')


def process(body):
    job_id = body['job_id']
    if len(job_id) != 32 or any(c not in '0123456789abcdef' for c in job_id):
        raise ValueError('Invalid job ID')
    prefix = f'jobs/{job_id}'
    status = json.loads(s3.get_object(Bucket=BUCKET, Key=f'{prefix}/status.json')['Body'].read())
    if status.get('state') == 'complete':
        log.info('Job %s already complete', job_id)
        return
    status['state'] = 'processing'
    put_json(f'{prefix}/status.json', status)
    delay = min(30, max(0, int(body.get('simulate_seconds', 0))))
    if delay:
        time.sleep(delay)  # Only for controlled Auto Scaling demonstration.
    raw = s3.get_object(Bucket=BUCKET, Key=f'{prefix}/raw.csv')['Body'].read()
    try:
        cleaned, report = clean_csv(raw)
        s3.put_object(Bucket=BUCKET, Key=f'{prefix}/cleaned.csv', Body=cleaned, ContentType='text/csv')
        put_json(f'{prefix}/report.json', report)
        status.update(state='complete', completed_at=int(time.time()), summary=report)
        put_json(f'{prefix}/status.json', status)
        log.info('Completed %s', job_id)
    except ValueError as exc:
        # Invalid CSV is a terminal input error, not an infrastructure failure.
        status.update(state='failed', error=str(exc))
        put_json(f'{prefix}/status.json', status)
        log.warning('Rejected %s: %s', job_id, exc)


def main():
    log.info('Worker ready, polling SQS')
    while True:
        try:
            response = sqs.receive_message(QueueUrl=QUEUE, MaxNumberOfMessages=1, WaitTimeSeconds=10, VisibilityTimeout=180)
            for msg in response.get('Messages', []):
                try:
                    process(json.loads(msg['Body']))
                    sqs.delete_message(QueueUrl=QUEUE, ReceiptHandle=msg['ReceiptHandle'])
                except Exception:
                    log.exception('Processing failed; SQS will retry message')
        except Exception:
            log.exception('Worker poll failed; retrying')
            time.sleep(5)


if __name__ == '__main__':
    main()
