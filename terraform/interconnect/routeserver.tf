# Azure Route Server — the missing piece that lets an in-VNet BGP speaker (the
# kubecompose frr-node ToR, running hostNetwork on an AKS node) inject routes the
# VPN gateway will then advertise to AWS. Today the gateway advertises only the VNet
# address space (10.224.0.0/12), so EC2 reaches AKS nodes but not the pod overlay
# (192.168.0.0/16). Route Server + branch-to-branch closes that gap:
#
#   FRR speaker --eBGP--> Route Server --(branch-to-branch)--> VPN gateway --BGP--> AWS
#
# Route Server's ASN is fixed at 65515 (same as the VPN gateway — both are Azure
# infra; Azure handles their internal exchange). The cluster speaker MUST use a
# different ASN (default 65001).

# Route Server requires a dedicated subnet named exactly "RouteServerSubnet", /27+.
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
  name                = "${var.name_prefix}-rs"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = var.azure_resource_group_name
  sku                 = "Standard"

  public_ip_address_id = azurerm_public_ip.route_server.id
  subnet_id            = azurerm_subnet.route_server.id

  # propagate routes between the Route Server (the cluster speaker) and the VPN
  # gateway — without this, pod CIDRs learned from FRR never reach AWS.
  branch_to_branch_traffic_enabled = true
}

# BGP peering to the in-cluster FRR speakers. The peer IPs are the system-pool node
# addresses, discovered from the VMSS rather than hardcoded — so a node reimage (which
# changes the instance IP) is picked up on the next apply instead of silently breaking
# the peering. AKS puts the node VMSS in a separate ("MC_...") resource group; find it by
# the aks-managed-poolName tag (survives resize, unlike the generated VMSS name).
#
# NOTE: point-in-time — re-apply after the system pool scales/reimages. Making this fully
# dynamic (auto-reconcile) is parked.
data "azurerm_kubernetes_cluster" "this" {
  name                = var.aks_cluster_name
  resource_group_name = var.azure_resource_group_name
}

data "azurerm_resources" "system_vmss" {
  resource_group_name = data.azurerm_kubernetes_cluster.this.node_resource_group
  type                = "Microsoft.Compute/virtualMachineScaleSets"
  required_tags = {
    "aks-managed-poolName" = var.system_pool_name
  }
}

data "azurerm_virtual_machine_scale_set" "system" {
  name                = data.azurerm_resources.system_vmss.resources[0].name
  resource_group_name = data.azurerm_kubernetes_cluster.this.node_resource_group
}

resource "azurerm_route_server_bgp_connection" "cluster" {
  for_each = {
    for i in data.azurerm_virtual_machine_scale_set.system.instances : i.name => i.private_ip_address
  }

  name            = "${var.name_prefix}-rs-${each.key}"
  route_server_id = azurerm_route_server.this.id
  peer_asn        = var.cluster_bgp_asn
  peer_ip         = each.value
}
