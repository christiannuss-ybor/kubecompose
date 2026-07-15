
data "aws_vpc" "this" {
  default = true
}

# Main VPC route table — holds the routes that send AKS-bound traffic to the TGW and deliver
# flex-pod-bound traffic to the flex EC2 (see flex-routing.tf).
data "aws_route_table" "main" {
  vpc_id = data.aws_vpc.this.id

  filter {
    name   = "association.main"
    values = ["true"]
  }
}

# Transit Gateway replaces the Virtual Private Gateway. Unlike the VGW (which only advertises
# prefixes inside the VPC CIDR), a TGW-terminated VPN advertises whatever is in its route
# table — so an arbitrary flex pod CIDR (172.20/24, NOT a VPC CIDR) can be advertised to Azure.
# It's also the aggregation point for many flex nodes (via static routes now, TGW Connect BGP
# later). ASN kept at amazon_side_asn (64512) so the Azure customer-gateway view is unchanged.
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
