variable "aws_region" {
  description = "AWS region to deploy in"
  type        = string
  default     = "ap-south-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "AMI ID for the EC2 instance"
  type        = string
  default     = "ami-01a00762f46d584a1"  # Amazon Linux 2, ap-south-1 — check current AMI for your region
}

variable "key_name" {
  description = "Name of the existing EC2 key pair for SSH access"
  type        = string
  default     = "88chinna"  # set this to your key pair name, or leave blank if not needed
}

variable "instance_name" {
  description = "Name tag for the EC2 instance"
  type        = string
  default     = "jenkins-terraform-demo"
}
