# Azure Route Server — DISABLED 2026-07-22 (YP6M-2839).
#
# Torn down to bring the ybor-playground stand-in into line with the customer's reality: their
# on-prem estate is a pervasive 10.0.0.0/8 (the AKS service CIDR 10.0.0.0/16 collides head-on), so
# the single-stretched-cluster + Route-Server model is dead for them. We're moving to a no-RS world
# (overlay / multi-cluster mesh) and want to observe the stand-in with the RS out of the datapath.
# The FRR relay is correspondingly gated OFF in values-ybor-playground.yaml (asn/routeServer unset).
#
# Resources preserved below (commented) for easy revert / history. GOTCHA on revert or removal: the
# VPN gateway needs `az network vnet-gateway reset` (both instances) to reconverge after RS changes.
/*
# Route Server requires a dedicated subnet named exactly "RouteServerSubnet", /27 or larger.
resource "azurerm_subnet" "route_server" {
  name                 = "RouteServerSubnet"
  resource_group_name  = var.azure_resource_group_name
  virtual_network_name = data.azurerm_virtual_network.this.name
  address_prefixes     = [var.azure_route_server_subnet_cidr]
}

resource "azurerm_public_ip" "route_server" {
  name                = "${var.name_prefix}-rs-pip"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = var.azure_resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

resource "azurerm_route_server" "this" {
  name                 = "${var.name_prefix}-rs"
  location             = data.azurerm_resource_group.this.location
  resource_group_name  = var.azure_resource_group_name
  sku                  = "Standard"
  public_ip_address_id = azurerm_public_ip.route_server.id
  subnet_id            = azurerm_subnet.route_server.id

  # Exchange routes between the Route Server and the VPN gateway — without this the pod CIDRs
  # the relay will inject never reach AWS.
  branch_to_branch_traffic_enabled = true
}

# BGP peering to the cluster relay: the bgp-chart speaker on the hardcoded relay node re-advertises
# the mesh's per-node pod /24s to the RS with next-hops preserved (see the bgp chart's relay block).
# Just ONE peer, so the Route Server 8-peer cap is a non-issue. peer_ip is the relay NODE's IP,
# hardcoded to match the bgp chart's relay.nodeIP — if that node reimages/scales its IP changes,
# so re-apply (point-in-time, same caveat the old per-VMSS peering carried).
resource "azurerm_route_server_bgp_connection" "relay" {
  name            = "${var.name_prefix}-rs-relay"
  route_server_id = azurerm_route_server.this.id
  peer_asn        = var.relay_asn
  peer_ip         = var.relay_peer_ip
}
*/
