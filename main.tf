terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

variable "aws_region" {
  description = "AWS region containing the default VPC."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS shared-config profile to authenticate with."
  type        = string
  default     = "ybor-playground-dev@p6m.dev"
}

# The provider must know its subscription before data sources can run,
# so this is the one Azure identifier that can't be looked up by name.
# GUID for the "ybor-playground" subscription.
variable "azure_subscription_id" {
  description = "Azure subscription containing the VNet."
  type        = string
  default     = "018bb159-9854-4df8-a51e-e327ae907b97"
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

provider "azurerm" {
  features {}
  subscription_id = var.azure_subscription_id
}

variable "bootstrap_token" {
  description = "Kubeadm-format bootstrap token for the flex node to TLS-join AKS. Supply via secrets.auto.tfvars (gitignored)."
  type        = string
  sensitive   = true
}

module "interconnect" {
  source = "./terraform/interconnect"

  # Wire the flex EC2s' subnets from the ec2 module so the TGW attachment covers every AZ a flex
  # node lands in (incl. the GPU node's AZ) — otherwise the control plane can't reach that node's
  # kubelet and exec/logs 504.
  flex_ec2_subnet_ids = module.ec2.subnet_ids
}

module "ec2" {
  source = "./terraform/ec2"

  bootstrap_token       = var.bootstrap_token
  azure_subscription_id = var.azure_subscription_id

  # The flex EC2 fleet: pod_cidr => { instance_type }. One node per entry. Defined here (not as a
  # module default) so the deployment's fleet is explicit at the root. GPU-family types automatically
  # get the p6m.dev/node-type=gpu-shared label and a GPU-capable AZ.
  flex_nodes = {
    "172.20.0.0/25" = { instance_type = "t3.large", termination_protection = false }
    "172.20.0.128/25" = {
      instance_type          = "g7e.2xlarge"
      termination_protection = true
      # Lets GPU-workload pods that tolerate nvidia.com/gpu:NoSchedule (operator: Exists) land here.
      taints       = ["nvidia.com/gpu:NoSchedule"]
      disk_size_gb = 500
    }
  }
}

output "aws_vpn_connection_id" {
  value = module.interconnect.aws_vpn_connection_id
}

output "aws_tunnel_addresses" {
  value = module.interconnect.aws_tunnel_addresses
}

output "azure_vpn_gateway_public_ip" {
  value = module.interconnect.azure_vpn_gateway_public_ip
}

output "bgp_sessions" {
  value = module.interconnect.bgp_sessions
}

output "ec2_public_ips" {
  value = module.ec2.public_ips
}

output "ec2_private_ips" {
  value = module.ec2.private_ips
}
