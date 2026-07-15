# Flex-node pod routing over the Transit Gateway.
#
# Advertise flex pods to Azure: a static TGW route (flex pod CIDR -> VPC attachment) puts the
# CIDR in the TGW route table, and the TGW-terminated VPN advertises it to Azure. No secondary
# VPC CIDR / gateway route table needed — the TGW advertises arbitrary prefixes, so the flex
# pod CIDR stays OUT of the VPC CIDR (which makes the plain VPC route -> ENI below legal).
resource "aws_ec2_transit_gateway_route" "flex_pods" {
  destination_cidr_block         = var.flex_pod_cidr
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway.this.association_default_route_table_id
}

# VPC route table: deliver flex-pod-bound traffic (arriving from the TGW) to the flex EC2's
# ENI — the bridge CNI hands it to the pod. Legal because flex_pod_cidr is outside the VPC
# CIDR (an in-VPC destination would need a matching subnet; an out-of-VPC one routes to an ENI
# directly). source/dest check is disabled on the instance (../ec2/main.tf) so it forwards.
resource "aws_route" "flex_pods_to_eni" {
  route_table_id         = data.aws_route_table.main.id
  destination_cidr_block = var.flex_pod_cidr
  network_interface_id   = var.flex_ec2_eni_id
}

# VPC -> AKS via the TGW: the flex EC2 reaches AKS pods (192.168/16) and nodes (10.224/12)
# through the transit gateway (which learns them over the VPN from Azure).
resource "aws_route" "aks_pods_via_tgw" {
  route_table_id         = data.aws_route_table.main.id
  destination_cidr_block = var.aks_pod_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
}

resource "aws_route" "aks_nodes_via_tgw" {
  route_table_id         = data.aws_route_table.main.id
  destination_cidr_block = var.azure_vnet_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
}
