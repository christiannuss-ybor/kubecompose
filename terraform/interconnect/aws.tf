
data "aws_vpc" "this" {
  default = true
}

data "aws_route_tables" "this" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
}

resource "aws_vpn_gateway" "this" {
  vpc_id          = data.aws_vpc.this.id
  amazon_side_asn = var.amazon_side_asn

  tags = {
    Name = "${var.name_prefix}-vgw"
  }
}

# The Azure VPN gateway's public IP is the "customer gateway" from AWS's
# point of view.
resource "aws_customer_gateway" "azure" {
  bgp_asn    = var.azure_asn
  ip_address = azurerm_public_ip.vpn_gateway.ip_address
  type       = "ipsec.1"

  tags = {
    Name = "${var.name_prefix}-cgw-azure"
  }

  # When the Azure public IP changes, the replacement gateway must exist
  # before the VPN connection can migrate off the old one; destroy-first
  # deadlocks on "customer gateway is in use".
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpn_connection" "azure" {
  vpn_gateway_id      = aws_vpn_gateway.this.id
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

resource "aws_vpn_gateway_route_propagation" "this" {
  for_each = toset(data.aws_route_tables.this.ids)

  vpn_gateway_id = aws_vpn_gateway.this.id
  route_table_id = each.value
}
