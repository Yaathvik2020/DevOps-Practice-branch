resource "aws_security_group" "demo_sg" {
  name        = "demo-instance-sg"
  description = "Allow SSH and HTTP"
  vpc_id      = data.aws_vpc.selected.id   # ← comes from 2-data.tf

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # restrict this to your IP in real usage
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "demo-instance-sg"
  }
}

resource "aws_instance" "tf_ec2" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name != "" ? var.key_name : null
  subnet_id               = tolist(data.aws_subnets.available.ids)[0]
  vpc_security_group_ids = [aws_security_group.demo_sg.id]

  tags = {
    Name = var.instance_name
  }
}

output "instance_public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.demo_ec2.public_ip
}

output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.demo_ec2.id
}

