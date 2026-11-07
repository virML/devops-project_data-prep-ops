variable "aws_region" {
  type = string
  default = "ap-south-1"
}
variable "key_name" {
  type = string
  description = "Existing EC2 SSH key pair in selected region"
}
variable "admin_cidr" {
  type = string
  description = "Your workstation public IPv4 with /32, for example 203.0.113.7/32"
}
variable "control_instance_type" {
  type = string
  default = "m7i-flex.large"
}
variable "worker_instance_type" {
  type = string
  default = "t3.micro"
}
variable "alert_email" {
  type = string
  default = ""
  description = "Optional email for AWS SNS alarm confirmation"
}
