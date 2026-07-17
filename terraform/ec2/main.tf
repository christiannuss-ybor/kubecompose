variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "aws-azure-vpn"
}

variable "instance_type" {
  description = "EC2 instance type. Bumped from t3.micro — the flex node runs kubelet + containerd + nspawn + a full set of AKS DaemonSets and starved at 1 GiB."
  type        = string
  default     = "t3.large"
}

variable "ssh_public_key" {
  description = "SSH public key installed on the instance."
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKSyUxz0DImCu44VTpH1FWDyKliJIYfgC1W+YAiB6j67 openpgp:0x79126151"
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH from the internet."
  type        = string
  default     = "98.113.40.21/32"
}

variable "azure_vnet_cidr" {
  description = "Azure VNet address space; all traffic from here is allowed for VPN testing."
  type        = string
  default     = "10.224.0.0/12"
}

# --- AKS Flex Node bootstrap (cloud-init) ---

variable "bootstrap_token" {
  description = "Kubeadm-format bootstrap token for the flex node to TLS-join AKS. Injected into the cloud-init config.json. Supply via secrets.auto.tfvars (gitignored)."
  type        = string
  sensitive   = true
}

variable "aks_cluster_name" {
  description = "AKS cluster the flex node joins."
  type        = string
  default     = "ybor-playground-dev-westus2"
}

variable "azure_resource_group_name" {
  description = "Resource group of the AKS cluster."
  type        = string
  default     = "ybor-playground-resource-group"
}

variable "azure_subscription_id" {
  description = "Azure subscription of the AKS cluster."
  type        = string
  default     = "018bb159-9854-4df8-a51e-e327ae907b97"
}

variable "azure_tenant_id" {
  description = "Azure tenant of the AKS cluster."
  type        = string
  default     = "32515de4-f9bc-4cb3-8aae-98c12c06f9d5"
}

variable "azure_location" {
  description = "Azure region of the AKS cluster."
  type        = string
  default     = "westus2"
}

variable "target_agentpool" {
  description = "AKS agent pool name the flex node registers under."
  type        = string
  default     = "aksflexnodes"
}

variable "k8s_version" {
  description = "Kubernetes version for the flex node components."
  type        = string
  default     = "1.33.8"
}

variable "dns_service_ip" {
  description = "Cluster DNS service IP."
  type        = string
  default     = "10.0.0.10"
}

variable "flex_pod_cidrs" {
  description = "Per-node pod CIDRs for the flex nodes' bridge CNI (host-local IPAM). One flex EC2 is created per entry (count), each getting its own non-overlapping /25 slice of 172.20.0.0/24."
  type        = list(string)
  default = [
    "172.20.0.0/25",
    "172.20.0.128/25",
  ]
}

variable "afn_version" {
  description = "aks-flex-node GitHub release tag to download. Must be a real release tag — the scheme is v0.1.x (e.g. v0.1.4, latest stable), NOT v0.14 (which 404s and aborts the cloud-init join)."
  type        = string
  default     = "v0.1.4"
}

data "aws_vpc" "this" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# The flex node joins this cluster; its FQDN + CA cert feed the kubelet config.
data "azurerm_kubernetes_cluster" "this" {
  name                = var.aks_cluster_name
  resource_group_name = var.azure_resource_group_name
}

locals {
  afn_url = "https://github.com/Azure/AKSFlexNode/releases/download/${var.afn_version}/aks-flex-node-linux-amd64.tar.gz"

  # One cloud-init per pod CIDR in var.flex_pod_cidrs, indexed by count.index. config.json + the
  # CNI conflist are rendered by jsonencode (proper escaping for the CA cert), base64'd, and
  # decoded in the cloud-init — no fragile heredoc interpolation. Everything is identical across
  # nodes except the pod CIDR: its own bridge-CNI range, and the node labels advertising it.
  cloud_init = [
    for pod_cidr in var.flex_pod_cidrs : templatefile("${path.module}/cloud-init.sh.tftpl", {
      afn_url = local.afn_url
      config_json_b64 = base64encode(jsonencode({
        azure = {
          subscriptionId          = var.azure_subscription_id
          tenantId                = var.azure_tenant_id
          resourceManagerEndpoint = "https://management.azure.com"
          targetAgentPoolName     = var.target_agentpool
          targetCluster = {
            resourceId = data.azurerm_kubernetes_cluster.this.id
            location   = var.azure_location
          }
          bootstrapToken = { token = var.bootstrap_token }
          arc            = { enabled = false }
        }
        agent      = { logLevel = "debug", logDir = "/var/log/aks-flex-node" }
        components = { kubernetes = var.k8s_version }
        networking = { dnsServiceIP = var.dns_service_ip }
        node = {
          kubelet = {
            clusterFQDN = data.azurerm_kubernetes_cluster.this.fqdn
            caCertData  = data.azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate
          }
          # Publish this node's pod CIDR as labels (kubelet --node-labels at registration) so it's
          # discoverable via kubectl. A label VALUE can't contain '/', so the CIDR is split into
          # network + prefix-length; rejoin with '/' to reconstruct. Same var as the CNI conf below.
          labels = {
            "flex.azure.com/pod-network" = split("/", pod_cidr)[0]
            "flex.azure.com/pod-prefix"  = split("/", pod_cidr)[1]
          }
          taints = ["flexnode=true:NoSchedule"]
        }
      }))
      cni_conf_b64 = base64encode(jsonencode({
        cniVersion = "1.0.0"
        name       = "flexnet"
        plugins = [
          {
            type        = "bridge"
            bridge      = "cni0"
            isGateway   = true
            ipMasq      = false
            hairpinMode = true
            ipam = {
              type   = "host-local"
              ranges = [[{ subnet = pod_cidr }]]
              routes = [{ dst = "0.0.0.0/0" }]
            }
          },
          { type = "portmap", capabilities = { portMappings = true } },
        ]
      }))
    })
  ]
}

resource "aws_key_pair" "this" {
  key_name   = "${var.name_prefix}-key"
  public_key = var.ssh_public_key
}

resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-ec2"
  description = "SSH from admin IP; everything from the Azure VNet via VPN"
  vpc_id      = data.aws_vpc.this.id

  ingress {
    description = "SSH from admin IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  ingress {
    description = "All traffic from Azure VNet over VPN"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.azure_vnet_cidr]
  }

  ingress {
    description = "All traffic between flex nodes in this SG (node + pod-to-pod)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-ec2"
  }
}

# Deterministic ENIs: minted here (not auto-created by the instances) so their IDs + private IPs
# stay stable across instance rebuilds — the interconnect TGW attachment doesn't churn, and each
# flex node keeps the same private IP / node name. src/dst check off (flex pods carry their own
# CIDR, so the instance forwards non-own-IP packets). One per pod CIDR in var.flex_pod_cidrs.
resource "aws_network_interface" "flex" {
  count             = length(var.flex_pod_cidrs)
  subnet_id         = sort(data.aws_subnets.default.ids)[0]
  security_groups   = [aws_security_group.this.id]
  source_dest_check = false

  tags = {
    Name = "${var.name_prefix}-flex-eni-${count.index}"
  }
}

# An explicit primary ENI doesn't get the subnet's auto-assigned public IP, so pin an EIP per
# node for SSH (also stable across rebuilds).
resource "aws_eip" "flex" {
  count  = length(var.flex_pod_cidrs)
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-flex-eip-${count.index}"
  }
}

resource "aws_eip_association" "flex" {
  count                = length(var.flex_pod_cidrs)
  allocation_id        = aws_eip.flex[count.index].id
  network_interface_id = aws_network_interface.flex[count.index].id
}

resource "aws_instance" "this" {
  count         = length(var.flex_pod_cidrs)
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.this.key_name

  network_interface {
    network_interface_id = aws_network_interface.flex[count.index].id
    device_index         = 0
  }

  # Bootstrap the AKS Flex Node via cloud-init; a config change rebuilds the instance
  # (the ENI + EIP persist, so the flex node's identity is stable).
  user_data                   = local.cloud_init[count.index]
  user_data_replace_on_change = true

  # AKS Flex Node needs ~8 GiB free in /var/lib for the nspawn rootfs + node artifacts.
  root_block_device {
    volume_size = 30
  }

  tags = {
    Name = "${var.name_prefix}-ec2-${count.index}"
  }
}

# Preserve node 0's stable ENI/EIP identity when the module went single-instance -> count[0]
# (so the first flex node isn't destroyed/recreated with a new private IP + node name).
moved {
  from = aws_network_interface.flex
  to   = aws_network_interface.flex[0]
}

moved {
  from = aws_eip.flex
  to   = aws_eip.flex[0]
}

moved {
  from = aws_eip_association.flex
  to   = aws_eip_association.flex[0]
}

moved {
  from = aws_instance.this
  to   = aws_instance.this[0]
}

output "public_ips" {
  value = aws_eip.flex[*].public_ip
}

output "private_ips" {
  value = aws_network_interface.flex[*].private_ip
}

output "eni_ids" {
  description = "Deterministic ENIs, one per flex node; stable across rebuilds."
  value       = aws_network_interface.flex[*].id
}

output "subnet_id" {
  description = "ENI subnet — used for the TGW VPC attachment (all nodes share one subnet)."
  value       = aws_network_interface.flex[0].subnet_id
}

output "flex_pod_cidrs" {
  description = "Per-node flex pod CIDRs (index-aligned with eni_ids), for the interconnect return-path routes."
  value       = var.flex_pod_cidrs
}
