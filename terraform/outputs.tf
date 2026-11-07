output "control_public_ip" { value = aws_instance.control.public_ip }
output "vpc_id" { value = aws_vpc.project.id }
output "worker_asg_name" { value = aws_autoscaling_group.workers.name }
output "s3_bucket" { value = aws_s3_bucket.data.bucket }
output "sqs_queue_url" { value = aws_sqs_queue.jobs.url }
output "sqs_queue_name" { value = aws_sqs_queue.jobs.name }
output "ecr_worker_uri" { value = aws_ecr_repository.worker.repository_url }
output "sns_topic_arn" { value = aws_sns_topic.alarms.arn }

output "aws_region" { value = var.aws_region }
output "control_private_ip" { value = aws_instance.control.private_ip }
