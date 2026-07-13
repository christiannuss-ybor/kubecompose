variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "aws-azure-vpn"
}

# --- AWS ---

variable "aws_region" {
  description = "AWS region containing the VPC."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS shared-config profile to authenticate with."
  type        = string
  default     = "ybor-playground-dev@p6m.dev"
}

variable "amazon_side_asn" {
  description = "BGP ASN of the AWS Virtual Private Gateway."
  type        = number
  default     = 64512
}

# --- Azure ---

# The provider must know its subscription before data sources can run,
# so this is the one Azure identifier that can't be looked up by name.
# GUID for the "ybor-playground" subscription.
variable "azure_subscription_id" {
  description = "Azure subscription containing the VNet."
  type        = string
  default     = "018bb159-9854-4df8-a51e-e327ae907b97"
}

variable "azure_resource_group_name" {
  description = "Existing resource group containing the VNet; VPN resources are created here too."
  type        = string
  default     = "ybor-playground-resource-group"
}

variable "azure_vnet_name" {
  description = "Name of the existing Azure VNet to connect."
  type        = string
  default     = "ybor-playground-dev-westus2"
}

variable "azure_gateway_subnet_cidr" {
  description = "CIDR for the GatewaySubnet to create in the VNet (/27 or larger recommended)."
  type        = string
  default     = "10.225.255.0/27"
}

variable "azure_asn" {
  description = "BGP ASN of the Azure VPN gateway. 65515 is Azure's default; AWS reserves 7224, Azure reserves 65515-65520 on the AWS side, so keep these distinct."
  type        = number
  default     = 65515
}

variable "azure_vpn_gateway_sku" {
  description = "Azure VPN gateway SKU. VpnGw1 = ~650 Mbps aggregate; scale up as needed."
  type        = string
  default     = "VpnGw1"
}

# --- Tunnels ---
# Inside CIDRs must be /30s from 169.254.21.0/24 or 169.254.22.0/24:
# the only APIPA ranges Azure accepts for custom BGP addresses, and both
# are outside AWS's reserved inside-CIDR list.

variable "tunnel1_inside_cidr" {
  description = "Link-local /30 for tunnel 1 BGP session (AWS gets .1, Azure gets .2)."
  type        = string
  default     = "169.254.21.0/30"
}

variable "tunnel2_inside_cidr" {
  description = "Link-local /30 for tunnel 2 BGP session (AWS gets .1, Azure gets .2)."
  type        = string
  default     = "169.254.22.0/30"
}
