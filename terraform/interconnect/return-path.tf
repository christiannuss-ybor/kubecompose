# Return path (AKS pods -> flex pods), STATIC de-risk version. Two pieces:
#  1. advertise the flex pod aggregate to Azure — a TGW static route puts 172.20.0.0/24 in the
#     TGW route table, which the TGW re-advertises to the Azure gateway over BGP; Azure then routes
#     172.20.x -> the gateway -> VPN -> TGW.
#  2. deliver returning traffic to the owning flex node — per-/25 VPC routes send each flex pod
#     range to that node's ENI (src/dst check is already off on the ENIs).
# This is the quick static stand-in for the BGP (TGW Connect) return path; rip it out once TGW
# Connect is in.
resource "aws_ec2_transit_gateway_route" "flex_pods" {
  destination_cidr_block         = var.flex_pod_supernet
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway.this.association_default_route_table_id
}

# Indices align with the ec2 module's count: flex_pod_cidrs[i] is node i's /25, flex_ec2_eni_ids[i]
# is node i's ENI.
resource "aws_route" "flex_pods_to_eni" {
  count                  = length(var.flex_pod_cidrs)
  route_table_id         = data.aws_route_table.main.id
  destination_cidr_block = var.flex_pod_cidrs[count.index]
  network_interface_id   = var.flex_ec2_eni_ids[count.index]
}
