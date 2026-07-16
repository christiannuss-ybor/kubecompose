variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "aws-azure-vpn"
}

# --- AWS ---

variable "amazon_side_asn" {
  description = "BGP ASN of the AWS Virtual Private Gateway."
  type        = number
  default     = 64512
}

# --- Azure ---

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

variable "azure_route_server_subnet_cidr" {
  description = "CIDR for the RouteServerSubnet (must be /27 or larger). Free block after GatewaySubnet."
  type        = string
  default     = "10.225.255.32/27"
}

variable "cluster_bgp_asn" {
  description = "ASN of the in-cluster FRR speaker that peers with Route Server. Must differ from Azure's 65515."
  type        = number
  default     = 65001
}

variable "aks_cluster_name" {
  description = "AKS cluster name (used to find the node resource group holding the system-pool VMSS)."
  type        = string
  default     = "ybor-playground-dev-westus2"
}

variable "system_pool_name" {
  description = "AKS system nodepool whose node IPs are registered as Route Server BGP peers (matched by the aks-managed-poolName VMSS tag)."
  type        = string
  default     = "systemd4psv6"
}

variable "azure_vpn_gateway_sku" {
  description = "Azure VPN gateway SKU. Only AZ SKUs can be created since the 2025 SKU consolidation. VpnGw1AZ = ~650 Mbps aggregate; scale up as needed."
  type        = string
  default     = "VpnGw1AZ"
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

# --- Flex-node pod routing (secondary CIDR + VGW edge route table) ---

variable "flex_pod_cidr" {
  description = "Flex node pod CIDR. Advertised to Azure via a static TGW route; kept OUT of the VPC CIDR so the plain VPC route -> flex ENI is legal (the TGW advertises arbitrary prefixes, so no secondary-CIDR trick is needed)."
  type        = string
  default     = "172.20.0.0/24"
}

# Wired from module.ec2 (aws_instance outputs) at the root, so the TGW attachment + VPC route
# follow the flex EC2 across rebuilds — no hardcoded ENI/subnet.
variable "flex_ec2_eni_id" {
  description = "ENI of the flex EC2 — the VPC route next hop for flex-pod-bound traffic."
  type        = string
}

variable "flex_ec2_subnet_id" {
  description = "Subnet the flex EC2 is in — used for the TGW VPC attachment."
  type        = string
}

variable "aks_pod_cidr" {
  description = "AKS cluster pod-CIDR aggregate, routed VPC -> TGW so the flex EC2 reaches AKS pods."
  type        = string
  default     = "192.168.0.0/16"
}

variable "azure_vnet_cidr" {
  description = "Azure VNet CIDR, routed VPC -> TGW so the flex EC2 reaches AKS nodes."
  type        = string
  default     = "10.224.0.0/12"
}

variable "metallb_vip_cidr" {
  description = "MetalLB service-VIP range (e.g. the kube-dns VIP 10.1.0.10), routed VPC -> TGW so the flex EC2 reaches BGP-advertised LoadBalancer VIPs."
  type        = string
  default     = "10.1.0.0/24"
}
