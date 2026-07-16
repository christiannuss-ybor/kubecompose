# Force the VPN gateway to deliver MetalLB service-VIP traffic (arriving from AWS) to the
# speaker node as an NVA.
#
# The gateway LEARNS the VIP /32 from the Route Server (control plane — confirmed via
# list-learned-routes) but does not install it for data-plane forwarding, so on-prem->VIP
# packets never reach the node (tcpdump on the node = 0 packets). A UDR on the GatewaySubnet
# makes the hand-off explicit: VIP range -> the speaker node (VirtualAppliance), which runs
# MetalLB/frr-k8s and whose Cilium kube-proxy-replacement then DNATs the VIP to a backend pod.
#
# Scoped to var.metallb_vip_cidr only (never 0.0.0.0/0), and BGP propagation stays enabled
# (route_table default), so the gateway's other learned routes (172.20/24, etc.) are untouched.
# next_hop is the system VMSS instance IP, data-sourced (survives node reimage on re-apply,
# like the Route Server peering). Single-speaker assumption: instances[0]; revisit for ECMP if
# the system pool grows past one MetalLB speaker.
resource "azurerm_route_table" "gateway_nva" {
  name                = "${var.name_prefix}-gw-nva-rt"
  location            = data.azurerm_resource_group.this.location
  resource_group_name = var.azure_resource_group_name
}

resource "azurerm_route" "vip_to_speaker" {
  name                   = "metallb-vips-to-speaker"
  resource_group_name    = var.azure_resource_group_name
  route_table_name       = azurerm_route_table.gateway_nva.name
  address_prefix         = var.metallb_vip_cidr
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = data.azurerm_virtual_machine_scale_set.system.instances[0].private_ip_address
}

resource "azurerm_subnet_route_table_association" "gateway" {
  subnet_id      = azurerm_subnet.gateway.id
  route_table_id = azurerm_route_table.gateway_nva.id
}
