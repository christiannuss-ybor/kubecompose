data "azurerm_resource_group" "this" {
  name = var.azure_resource_group_name
}

data "azurerm_virtual_network" "this" {
  name                = var.azure_vnet_name
  resource_group_name = var.azure_resource_group_name
}

# Azure requires the gateway subnet to be named exactly "GatewaySubnet".
resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = var.azure_resource_group_name
  virtual_network_name = data.azurerm_virtual_network.this.name
  address_prefixes     = [var.azure_gateway_subnet_cidr]
}

# Inherits create_before_destroy from aws_customer_gateway (lifecycle
# propagates to dependencies), so any change that replaces this IP will
# collide on the name. Delete the old IP out-of-band first, or rename.
resource "azurerm_public_ip" "vpn_gateway" {
  name                = "${var.name_prefix}-vpngw-pip"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = var.azure_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

# Second instance PIP. Leftover from the (now-removed) Azure Route Server, which refused to
# coexist with an active-standby gateway and forced active-active (requiring a second
# ip_configuration + PIP). We keep active-active rather than reconfigure the live gateway (a
# disruptive reset): this second instance is idle ballast — AWS terminates both tunnels on
# instance 0 (below), so nothing connects here.
resource "azurerm_public_ip" "vpn_gateway_2" {
  name                = "${var.name_prefix}-vpngw-pip2"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = var.azure_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

locals {
  # AWS assigns itself the first host of each inside CIDR; Azure takes the second.
  tunnel1_aws_bgp_ip   = cidrhost(var.tunnel1_inside_cidr, 1)
  tunnel1_azure_bgp_ip = cidrhost(var.tunnel1_inside_cidr, 2)
  tunnel2_aws_bgp_ip   = cidrhost(var.tunnel2_inside_cidr, 1)
  tunnel2_azure_bgp_ip = cidrhost(var.tunnel2_inside_cidr, 2)
  # APIPA for the idle second gateway instance. Azure requires active-active
  # instances to declare an EQUAL number of custom BGP addresses, so instance 1
  # gets two to match instance 0 — from distinct /30s (169.254.21.4/30,
  # .22.4/30) that never collide with the two AWS tunnel /30s. Unused: no AWS
  # tunnel terminates on this instance.
  instance1_bgp_ips = ["169.254.21.6", "169.254.22.6"]
}

resource "azurerm_virtual_network_gateway" "this" {
  name                = "${var.name_prefix}-vpngw"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = var.azure_resource_group_name

  type          = "Vpn"
  vpn_type      = "RouteBased"
  sku           = var.azure_vpn_gateway_sku
  generation    = "Generation1"
  active_active = true
  bgp_enabled   = true

  # instance 0 — keeps the existing PIP + APIPA, so the AWS customer gateway
  # and both live BGP sessions are untouched.
  ip_configuration {
    name                          = "default"
    public_ip_address_id          = azurerm_public_ip.vpn_gateway.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway.id
  }

  # instance 1 — required for active-active; nothing on AWS connects to it.
  ip_configuration {
    name                          = "activeActive"
    public_ip_address_id          = azurerm_public_ip.vpn_gateway_2.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway.id
  }

  bgp_settings {
    asn = var.azure_asn

    peering_addresses {
      ip_configuration_name = "default"
      apipa_addresses = [
        local.tunnel1_azure_bgp_ip,
        local.tunnel2_azure_bgp_ip,
      ]
    }

    # instance 1's APIPA — two addresses to match instance 0's count (Azure's
    # AddEqual rule), distinct /30s from the AWS tunnels, unused.
    peering_addresses {
      ip_configuration_name = "activeActive"
      apipa_addresses       = local.instance1_bgp_ips
    }
  }
}

# One local network gateway per AWS tunnel endpoint.
resource "azurerm_local_network_gateway" "aws_tunnel1" {
  name                = "${var.name_prefix}-lng-aws-t1"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = var.azure_resource_group_name
  gateway_address     = aws_vpn_connection.azure.tunnel1_address

  bgp_settings {
    asn                 = var.amazon_side_asn
    bgp_peering_address = local.tunnel1_aws_bgp_ip
  }
}

resource "azurerm_local_network_gateway" "aws_tunnel2" {
  name                = "${var.name_prefix}-lng-aws-t2"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = var.azure_resource_group_name
  gateway_address     = aws_vpn_connection.azure.tunnel2_address

  bgp_settings {
    asn                 = var.amazon_side_asn
    bgp_peering_address = local.tunnel2_aws_bgp_ip
  }
}

resource "azurerm_virtual_network_gateway_connection" "aws_tunnel1" {
  name                = "${var.name_prefix}-conn-aws-t1"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = var.azure_resource_group_name

  type                       = "IPsec"
  connection_protocol        = "IKEv2"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.this.id
  local_network_gateway_id   = azurerm_local_network_gateway.aws_tunnel1.id
  shared_key                 = aws_vpn_connection.azure.tunnel1_preshared_key
  bgp_enabled                = true

  # active-active: connection must name an APIPA for BOTH gateway instances.
  # primary = instance 0 (the one AWS actually terminates on); secondary =
  # instance 1's (idle, but Azure requires it declared).
  custom_bgp_addresses {
    primary   = local.tunnel1_azure_bgp_ip
    secondary = local.instance1_bgp_ips[0]
  }
}

resource "azurerm_virtual_network_gateway_connection" "aws_tunnel2" {
  name                = "${var.name_prefix}-conn-aws-t2"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = var.azure_resource_group_name

  type                       = "IPsec"
  connection_protocol        = "IKEv2"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.this.id
  local_network_gateway_id   = azurerm_local_network_gateway.aws_tunnel2.id
  shared_key                 = aws_vpn_connection.azure.tunnel2_preshared_key
  bgp_enabled                = true

  custom_bgp_addresses {
    primary   = local.tunnel2_azure_bgp_ip
    secondary = local.instance1_bgp_ips[1]
  }
}
