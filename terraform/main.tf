terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
provider "aws" { region = var.aws_region }

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name = "architecture"
    values = ["x86_64"]
  }
  filter {
    name = "virtualization-type"
    values = ["hvm"]
  }
}
resource "random_id" "suffix" { byte_length = 3 }
locals {
  name = "dataprepops-${random_id.suffix.hex}"
}

resource "aws_vpc" "project" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${local.name}-vpc", Project = "DataPrepOps" }
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.project.id
  tags = { Name = "${local.name}-igw" }
}
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.project.id
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  cidr_block              = cidrsubnet(aws_vpc.project.cidr_block, 8, count.index + 1)
  map_public_ip_on_launch = true
  tags = { Name = "${local.name}-subnet-${count.index + 1}" }
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.project.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${local.name}-public-rt" }
}
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
resource "aws_security_group" "control" {
  name        = "${local.name}-control"
  description = "Restricted classroom access to control server"
  vpc_id      = aws_vpc.project.id
  tags = { Name = "${local.name}-control" }
}
resource "aws_vpc_security_group_ingress_rule" "admin_ssh" {
  security_group_id = aws_security_group.control.id
  cidr_ipv4 = var.admin_cidr
  ip_protocol = "tcp"
  from_port = 22
  to_port = 22
  description = "SSH from the student's address; application consoles use SSH forwarding"
}
resource "aws_vpc_security_group_egress_rule" "control" {
  security_group_id = aws_security_group.control.id
  cidr_ipv4 = "0.0.0.0/0"
  ip_protocol = "-1"
}
resource "aws_security_group" "worker" {
  name        = "${local.name}-workers"
  description = "No inbound access; outbound for S3 SQS ECR and packages"
  vpc_id      = aws_vpc.project.id
  tags = { Name = "${local.name}-workers" }
}
resource "aws_vpc_security_group_egress_rule" "worker" {
  security_group_id = aws_security_group.worker.id
  cidr_ipv4 = "0.0.0.0/0"
  ip_protocol = "-1"
}

resource "aws_s3_bucket" "data" {
  bucket        = "dataprepops-${data.aws_caller_identity.current.account_id}-${random_id.suffix.hex}"
  force_destroy = true # Demo bucket only: terraform destroy deletes the contents.
  tags = { Project = "DataPrepOps" }
}
resource "aws_s3_bucket_public_access_block" "data" {
  bucket = aws_s3_bucket.data.id
  block_public_acls = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_policy" "deny_insecure_transport" {
  bucket = aws_s3_bucket.data.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid = "RequireTLS"
      Effect = "Deny"
      Principal = "*"
      Action = "s3:*"
      Resource = [aws_s3_bucket.data.arn, "${aws_s3_bucket.data.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}
resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
resource "aws_sqs_queue" "dlq" {
  name = "${local.name}-failed"
  message_retention_seconds = 345600
}
resource "aws_sqs_queue" "jobs" {
  name                       = "${local.name}-jobs"
  receive_wait_time_seconds  = 10
  visibility_timeout_seconds = 180
  redrive_policy = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dlq.arn, maxReceiveCount = 3 })
}
resource "aws_ecr_repository" "worker" {
  name = "${local.name}-worker"
  force_delete = true
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_iam_role" "control" {
  name = "${local.name}-control-role"
  assume_role_policy = jsonencode({ Version="2012-10-17", Statement=[{Effect="Allow", Principal={Service="ec2.amazonaws.com"}, Action="sts:AssumeRole"}] })
}
resource "aws_iam_role" "worker" {
  name = "${local.name}-worker-role"
  assume_role_policy = jsonencode({ Version="2012-10-17", Statement=[{Effect="Allow", Principal={Service="ec2.amazonaws.com"}, Action="sts:AssumeRole"}] })
}
resource "aws_iam_role_policy" "control" {
  role = aws_iam_role.control.id
  policy = jsonencode({ Version="2012-10-17", Statement=[
    {Effect="Allow",Action=["s3:ListBucket"],Resource=[aws_s3_bucket.data.arn]},
    {Effect="Allow",Action=["s3:GetObject","s3:PutObject"],Resource=["${aws_s3_bucket.data.arn}/*"]},
    {Effect="Allow",Action=["sqs:SendMessage","sqs:GetQueueAttributes"],Resource=[aws_sqs_queue.jobs.arn]},
    {Effect="Allow",Action=["ecr:GetAuthorizationToken"],Resource=["*"]},
    {Effect="Allow",Action=["ecr:BatchCheckLayerAvailability","ecr:CompleteLayerUpload","ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:PutImage","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer"],Resource=[aws_ecr_repository.worker.arn]}
  ]})
}
resource "aws_iam_role_policy" "worker" {
  role = aws_iam_role.worker.id
  policy = jsonencode({ Version="2012-10-17", Statement=[
    {Effect="Allow",Action=["s3:GetObject","s3:PutObject"],Resource=["${aws_s3_bucket.data.arn}/*"]},
    {Effect="Allow",Action=["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"],Resource=[aws_sqs_queue.jobs.arn]},
    {Effect="Allow",Action=["ecr:GetAuthorizationToken"],Resource=["*"]},
    {Effect="Allow",Action=["ecr:BatchGetImage","ecr:GetDownloadUrlForLayer"],Resource=[aws_ecr_repository.worker.arn]}
  ]})
}
resource "aws_iam_instance_profile" "control" {
  name = "${local.name}-control-profile"
  role = aws_iam_role.control.name
}
resource "aws_iam_instance_profile" "worker" {
  name = "${local.name}-worker-profile"
  role = aws_iam_role.worker.name
}

resource "aws_instance" "control" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.control_instance_type
  subnet_id                   = aws_subnet.public[0].id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.control.id]
  iam_instance_profile        = aws_iam_instance_profile.control.name
  key_name                    = var.key_name
  root_block_device {
    volume_size = 45
    volume_type = "gp3"
    encrypted = true
  }
  metadata_options {
    http_tokens = "required"
    http_put_response_hop_limit = 3
  }
  tags = { Name = "${local.name}-control", Project = "DataPrepOps", Role = "Control" }
  depends_on = [aws_route_table_association.public]
}
resource "aws_launch_template" "worker" {
  name_prefix   = "${local.name}-worker-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.worker_instance_type
  iam_instance_profile { name = aws_iam_instance_profile.worker.name }
  user_data = base64encode(templatefile("${path.module}/worker-userdata.sh.tftpl", {
    aws_region          = var.aws_region
    ecr_repository_uri  = aws_ecr_repository.worker.repository_url
    s3_bucket           = aws_s3_bucket.data.bucket
    sqs_queue_url       = aws_sqs_queue.jobs.url
  }))
  metadata_options {
    http_tokens="required"
    http_put_response_hop_limit=3
    http_endpoint="enabled"
  }
  network_interfaces {
    device_index = 0
    associate_public_ip_address = true
    security_groups = [aws_security_group.worker.id]
    delete_on_termination = true
  }
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 14
      volume_type="gp3"
      encrypted=true
      delete_on_termination=true
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags = { Name="${local.name}-processing-worker", Project="DataPrepOps", Role="Worker" }
  }
}
resource "aws_autoscaling_group" "workers" {
  name                = "${local.name}-worker-asg"
  min_size            = 2
  desired_capacity    = 2
  max_size            = 3
  vpc_zone_identifier = [for s in aws_subnet.public : s.id]
  health_check_type   = "EC2"
  launch_template {
    id = aws_launch_template.worker.id
    version = "$Latest"
  }
  tag {
    key = "Name"
    value = "${local.name}-processing-worker"
    propagate_at_launch = true
  }
  tag {
    key = "Project"
    value = "DataPrepOps"
    propagate_at_launch = true
  }
  lifecycle { ignore_changes = [desired_capacity] }
  depends_on = [aws_route_table_association.public]
}
resource "aws_autoscaling_policy" "scale_out" {
  name = "${local.name}-queue-scale-out"
  autoscaling_group_name = aws_autoscaling_group.workers.name
  adjustment_type = "ChangeInCapacity"
  scaling_adjustment = 1
  cooldown = 180
}
resource "aws_autoscaling_policy" "scale_in" {
  name = "${local.name}-queue-scale-in"
  autoscaling_group_name = aws_autoscaling_group.workers.name
  adjustment_type = "ChangeInCapacity"
  scaling_adjustment = -1
  cooldown = 180
}
resource "aws_sns_topic" "alarms" { name = "${local.name}-alarms" }
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol = "email"
  endpoint = var.alert_email
}
resource "aws_cloudwatch_metric_alarm" "queue_high" {
  alarm_name = "${local.name}-sqs-backlog-high"
  namespace = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  dimensions = { QueueName = aws_sqs_queue.jobs.name }
  statistic = "Maximum"
  period = 60
  evaluation_periods = 2
  threshold = 8
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data = "notBreaching"
  alarm_actions = [aws_autoscaling_policy.scale_out.arn, aws_sns_topic.alarms.arn]
  ok_actions = [aws_sns_topic.alarms.arn]
}
resource "aws_cloudwatch_metric_alarm" "queue_empty" {
  alarm_name = "${local.name}-sqs-backlog-empty"
  namespace = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  dimensions = { QueueName = aws_sqs_queue.jobs.name }
  statistic = "Maximum"
  period = 60
  evaluation_periods = 4
  threshold = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data = "notBreaching"
  alarm_actions = [aws_autoscaling_policy.scale_in.arn]
}
