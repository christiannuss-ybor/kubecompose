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

resource "azurerm_public_ip" "vpn_gateway" {
  name                = "${var.name_prefix}-vpngw-pip"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = var.azure_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

locals {
  # AWS assigns itself the first host of each inside CIDR; Azure takes the second.
  tunnel1_aws_bgp_ip   = cidrhost(var.tunnel1_inside_cidr, 1)
  tunnel1_azure_bgp_ip = cidrhost(var.tunnel1_inside_cidr, 2)
  tunnel2_aws_bgp_ip   = cidrhost(var.tunnel2_inside_cidr, 1)
  tunnel2_azure_bgp_ip = cidrhost(var.tunnel2_inside_cidr, 2)
}

resource "azurerm_virtual_network_gateway" "this" {
  name                = "${var.name_prefix}-vpngw"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = var.azure_resource_group_name

  type          = "Vpn"
  vpn_type      = "RouteBased"
  sku           = var.azure_vpn_gateway_sku
  generation    = "Generation1"
  active_active = false
  bgp_enabled   = true

  ip_configuration {
    name                          = "default"
    public_ip_address_id          = azurerm_public_ip.vpn_gateway.id
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

  custom_bgp_addresses {
    primary = local.tunnel1_azure_bgp_ip
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
    primary = local.tunnel2_azure_bgp_ip
  }
}
