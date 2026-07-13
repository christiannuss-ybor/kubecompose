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

variable "cluster_bgp_peer_ip" {
  description = "VNet IP (AKS node) of the in-cluster FRR speaker peering Route Server. Empty = no peering."
  type        = string
  default     = ""
}

variable "cluster_bgp_asn" {
  description = "ASN of the in-cluster FRR speaker."
  type        = number
  default     = 65001
}

module "interconnect" {
  source = "./terraform/interconnect"

  cluster_bgp_peer_ip = var.cluster_bgp_peer_ip
  cluster_bgp_asn     = var.cluster_bgp_asn
}

module "ec2" {
  source = "./terraform/ec2"
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

output "ec2_public_ip" {
  value = module.ec2.public_ip
}

output "ec2_private_ip" {
  value = module.ec2.private_ip
}
