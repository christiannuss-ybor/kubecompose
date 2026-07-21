variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "aws-azure-vpn"
}

# --- AWS ---

variable "amazon_side_asn" {
  description = "BGP ASN of the AWS Transit Gateway."
  type        = number
  default     = 64512
}

variable "flex_ec2_subnet_id" {
  description = "A VPC subnet for the TGW VPC attachment (the subnet the flex EC2 lives in)."
  type        = string
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

variable "azure_vnet_cidr" {
  description = "Azure VNet address space, routed VPC -> TGW so the VPC reaches AKS nodes."
  type        = string
  default     = "10.224.0.0/12"
}

variable "aks_pod_cidr" {
  description = "AKS pod overlay aggregate, routed VPC -> TGW so the flex node can reach the AKS pods it needs (CoreDNS + istiod, on the system node). Kept as the full /16 on purpose, NOT narrowed to the system node's single /24: AKS scatters per-node /24s unpredictably across the /16 and the system node can churn to a new one, so a /16 route stays valid with no re-apply. Only the /24 the Route Server actually injects (the system node's own, next-hop=that node) is reachable anyway — every other /24 black-holes at Azure by design (those node NICs lack IP-forwarding), so the broad route re-exposes nothing."
  type        = string
  default     = "192.168.0.0/16"
}

variable "azure_gateway_subnet_cidr" {
  description = "CIDR for the GatewaySubnet to create in the VNet (/27 or larger recommended)."
  type        = string
  default     = "10.225.255.0/27"
}

variable "azure_route_server_subnet_cidr" {
  description = "CIDR for the RouteServerSubnet (a free /27 in the VNet; Azure requires the subnet named exactly RouteServerSubnet). Sits just after the GatewaySubnet."
  type        = string
  default     = "10.225.255.32/27"
}

variable "relay_peer_ip" {
  description = "IP of the cluster relay node the Route Server BGP-peers — the bgp chart's relay.nodeIP. Hardcoded to the stable AKS system node; re-apply if that node's IP changes."
  type        = string
  default     = "10.224.0.108"
}

variable "relay_asn" {
  description = "BGP ASN of the cluster relay (the bgp chart's node speakers). Must differ from the Azure ASN (65515)."
  type        = number
  default     = 65001
}

variable "azure_asn" {
  description = "BGP ASN of the Azure VPN gateway. 65515 is Azure's default; AWS reserves 7224, Azure reserves 65515-65520 on the AWS side, so keep these distinct."
  type        = number
  default     = 65515
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
