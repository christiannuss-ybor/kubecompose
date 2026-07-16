output "aws_vpn_connection_id" {
  description = "ID of the AWS site-to-site VPN connection."
  value       = aws_vpn_connection.azure.id
}

output "aws_tunnel_addresses" {
  description = "Public IPs of the two AWS tunnel endpoints."
  value = [
    aws_vpn_connection.azure.tunnel1_address,
    aws_vpn_connection.azure.tunnel2_address,
  ]
}

output "azure_vpn_gateway_public_ip" {
  description = "Public IP of the Azure VPN gateway."
  value       = azurerm_public_ip.vpn_gateway.ip_address
}

output "bgp_sessions" {
  description = "BGP peering addresses per tunnel (aws_ip <-> azure_ip)."
  value = {
    tunnel1 = { aws = local.tunnel1_aws_bgp_ip, azure = local.tunnel1_azure_bgp_ip }
    tunnel2 = { aws = local.tunnel2_aws_bgp_ip, azure = local.tunnel2_azure_bgp_ip }
  }
}
