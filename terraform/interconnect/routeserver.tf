# Azure Route Server — re-introduced to inject the cluster's per-node pod routes into the VNet
# so the VPN gateway advertises them to AWS (the forward-path datapath for cross-cloud pod-to-
# pod). Today the gateway advertises only the VNet address space (10.224.0.0/12), so EC2 reaches
# AKS nodes but not the pod overlay (192.168.0.0/16). Route Server + branch-to-branch closes it:
#
#   relay FRR --eBGP(next-hop unchanged)--> Route Server --(branch-to-branch)--> VPN gateway --> AWS
#
# INCREMENT 1: the Route Server, its subnet, and PIP only. With branch-to-branch on it peers the
# VPN gateway automatically, but has no cluster BGP peers yet — so it injects nothing and cannot
# perturb the working node-to-node path. The relay peering (a small set, NOT every node) comes
# next. RS ASN is fixed at 65515 (same as the gateway; both are Azure infra).

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
