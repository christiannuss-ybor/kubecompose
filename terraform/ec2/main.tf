variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "aws-azure-vpn"
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}

variable "ssh_public_key" {
  description = "SSH public key installed on the instance."
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKSyUxz0DImCu44VTpH1FWDyKliJIYfgC1W+YAiB6j67 openpgp:0x79126151"
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH from the internet."
  type        = string
  default     = "98.113.40.21/32"
}

variable "azure_vnet_cidr" {
  description = "Azure VNet address space; all traffic from here is allowed for VPN testing."
  type        = string
  default     = "10.224.0.0/12"
}

data "aws_vpc" "this" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "this" {
  key_name   = "${var.name_prefix}-key"
  public_key = var.ssh_public_key
}

resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-ec2"
  description = "SSH from admin IP; everything from the Azure VNet via VPN"
  vpc_id      = data.aws_vpc.this.id

  ingress {
    description = "SSH from admin IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  ingress {
    description = "All traffic from Azure VNet over VPN"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.azure_vnet_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-ec2"
  }
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = sort(data.aws_subnets.default.ids)[0]
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.this.id]

  # AKS Flex Node needs ~8 GiB free in /var/lib for the nspawn rootfs + node artifacts;
  # the AMI's default 8 GiB root is too small.
  root_block_device {
    volume_size = 30
  }

  tags = {
    Name = "${var.name_prefix}-ec2"
  }
}

output "public_ip" {
  value = aws_instance.this.public_ip
}

output "private_ip" {
  value = aws_instance.this.private_ip
}
