terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

# Instance Vars
locals {
  instance_type = "t3.medium"
  ami_owner     = "099720109477"
  ami_name      = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
  aws_region    = "us-west-2"
}

provider "aws" {
  region = local.aws_region
}

# VPC
resource "aws_vpc" "crafty_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_subnet" "crafty_subnet" {
  vpc_id                  = aws_vpc.crafty_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${local.aws_region}a"
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "crafty_igw" {
  vpc_id = aws_vpc.crafty_vpc.id
}

resource "aws_route_table" "crafty_rt" {
  vpc_id = aws_vpc.crafty_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.crafty_igw.id
  }
}

resource "aws_route_table_association" "crafty_rta" {
  subnet_id      = aws_subnet.crafty_subnet.id
  route_table_id = aws_route_table.crafty_rt.id
}

# Security Group
resource "aws_security_group" "crafty_sg" {
  name        = "crafty-sg"
  description = "Allow SSH, HTTP, HTTPS, Minecraft, Geyser"
  vpc_id      = aws_vpc.crafty_vpc.id

  ingress { # Allow SSH from my IP
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress { # Allow seeing the map from my IP
    from_port   = 8123
    to_port     = 8123
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress { # Allow HTTP from anywhere
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress { # Allow HTTPS from anywhere
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress { # Allow Minecraft Bedrock from anywhere
    from_port   = 19132
    to_port     = 19132
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress { # Allow Minecraft Java from anywhere
    from_port   = 25500
    to_port     = 25600
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress { # Allow all outbound traffic
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM Role for EC2 S3 access
resource "aws_iam_role" "minecraft_ec2_role" {
  name = "ec2-minecraft-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ec2_s3_policy" {
  name = "s3-access"
  role = aws_iam_role.minecraft_ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      Resource = [
        "arn:aws:s3:::${var.s3_bucket}",
        "arn:aws:s3:::${var.s3_bucket}/*"
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-minecraft-profile"
  role = aws_iam_role.minecraft_ec2_role.name
}

# S3 Bucket for backups
resource "aws_s3_bucket" "crafty_backup" {
  bucket = var.s3_bucket
}

resource "aws_s3_bucket_public_access_block" "crafty_backup_public_access" {
  bucket = aws_s3_bucket.crafty_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "crafty_backup_policy" {
  bucket = aws_s3_bucket.crafty_backup.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowEC2RoleListBucket",
        Effect = "Allow",
        Principal = {
          AWS = aws_iam_role.minecraft_ec2_role.arn
        },
        Action   = ["s3:ListBucket"],
        Resource = [aws_s3_bucket.crafty_backup.arn]
      },
      {
        Sid    = "AllowEC2RoleObjectActions",
        Effect = "Allow",
        Principal = {
          AWS = aws_iam_role.minecraft_ec2_role.arn
        },
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ],
        Resource = [format("%s/*", aws_s3_bucket.crafty_backup.arn)]
      }
    ]
  })
}


resource "aws_eip" "crafty_eip" {}

resource "aws_eip_association" "crafty_eip_assoc" {
  instance_id   = aws_instance.crafty.id
  allocation_id = aws_eip.crafty_eip.id
}

resource "aws_route53_record" "crafty_dns" {
  zone_id = var.zone_id
  name    = var.fqdn
  type    = "A"
  ttl     = 300
  records = [aws_eip.crafty_eip.public_ip]
}

# EBS Volume
resource "aws_ebs_volume" "crafty_data" {
  availability_zone = aws_subnet.crafty_subnet.availability_zone
  size              = 10
  type              = "gp3"
  tags = {
    Name = "crafty-data-volume"
  }
}

# Latest Ubuntu AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = [local.ami_owner]

  filter {
    name   = "name"
    values = [local.ami_name]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_volume_attachment" "crafty_data_attach" {
  device_name  = "/dev/xvdb"
  volume_id    = aws_ebs_volume.crafty_data.id
  instance_id  = aws_instance.crafty.id
  force_detach = true
  depends_on   = [aws_instance.crafty]
}

# EC2 Instance with embedded user_data
resource "aws_instance" "crafty" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = local.instance_type
  subnet_id                   = aws_subnet.crafty_subnet.id
  vpc_security_group_ids      = [aws_security_group.crafty_sg.id]
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    domain_name = var.fqdn,
    admin_email = var.admin_email,
    s3_bucket   = var.s3_bucket
  })

  tags = {
    Name = "crafty-minecraft-server"
  }
}
