
data "aws_vpc" "this" {
  default = true
}

# Main VPC route table — holds the route that sends Azure-VNet-bound traffic to the TGW.
data "aws_route_table" "main" {
  vpc_id = data.aws_vpc.this.id

  filter {
    name   = "association.main"
    values = ["true"]
  }
}

# Transit Gateway terminates the Azure VPN and acts as the VPC's BGP router: it advertises its
# route table (the VPC CIDR, propagated from the attachment) to Azure and learns the Azure VNet
# address space in return. Only node/subnet ranges cross the VPN — pod overlays are never put in
# the TGW route table, so they are not advertised. ASN kept at amazon_side_asn (64512) so the
# Azure customer-gateway view is unchanged.
resource "aws_ec2_transit_gateway" "this" {
  description                     = "${var.name_prefix} Azure VPN and flex nodes"
  amazon_side_asn                 = var.amazon_side_asn
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"

  tags = {
    Name = "${var.name_prefix}-tgw"
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = data.aws_vpc.this.id
  subnet_ids         = [var.flex_ec2_subnet_id]

  tags = {
    Name = "${var.name_prefix}-tgw-vpc"
  }
}

# The Azure VPN gateway's public IP is the "customer gateway" from AWS's point of view.
resource "aws_customer_gateway" "azure" {
  bgp_asn    = var.azure_asn
  ip_address = azurerm_public_ip.vpn_gateway.ip_address
  type       = "ipsec.1"

  tags = {
    Name = "${var.name_prefix}-cgw-azure"
  }

  # When the Azure public IP changes, the replacement gateway must exist before the VPN
  # connection can migrate off the old one; destroy-first deadlocks on "customer gateway is
  # in use".
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpn_connection" "azure" {
  transit_gateway_id  = aws_ec2_transit_gateway.this.id
  customer_gateway_id = aws_customer_gateway.azure.id
  type                = "ipsec.1"
  static_routes_only  = false

  tunnel1_inside_cidr  = var.tunnel1_inside_cidr
  tunnel2_inside_cidr  = var.tunnel2_inside_cidr
  tunnel1_ike_versions = ["ikev2"]
  tunnel2_ike_versions = ["ikev2"]

  tags = {
    Name = "${var.name_prefix}-vpn"
  }
}

# VPC -> Azure over the VPN: the VPC (incl. the flex EC2) reaches the Azure VNet address space
# (AKS nodes, 10.224.0.0/12) via the TGW, which learns it over BGP from the Azure VPN gateway.
# Node-to-node only: the AKS pod overlay (192.168/16) and the flex CNI (172.20/24) are never
# advertised, so they stay unreachable across the interconnect by design.
resource "aws_route" "aks_nodes_via_tgw" {
  route_table_id         = data.aws_route_table.main.id
  destination_cidr_block = var.azure_vnet_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
}
