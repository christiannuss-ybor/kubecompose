variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "aws-azure-vpn"
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
  description = "Cluster DNS the flex nodes use as --cluster-dns. Points at the flex-node-system chart's system-node CoreDNS VIP (10.0.0.100 = kube-dns 10.0.0.10 + \"0\", the chart's derived value), NOT the cluster-wide kube-dns (10.0.0.10) — kube-dns endpoints spread onto Karpenter nodes whose NICs lack IP-forwarding and are unreachable from a flex node. Must match system.coredns.clusterIP in values-ybor-playground.yaml. Per-node kubelet flag, so the rest of the cluster is unaffected."
  type        = string
  default     = "10.0.0.100"
}

variable "flex_nodes" {
  description = "The flex EC2 fleet as pod_cidr => { attributes }. One EC2 per entry: the key is that node's bridge-CNI pod /25 (host-local IPAM, a non-overlapping slice of 172.20.0.0/24); the value is a per-node attribute map. Attributes: instance_type; termination_protection (EC2 DisableApiTermination — true blocks terraform from terminating/replacing it until flipped back). GPU-family types (nonzero GPUs, e.g. g7e.2xlarge) automatically get the p6m.dev/node-type=gpu-shared node label and are placed in an AZ that offers the type."
  type = map(object({
    instance_type          = string
    termination_protection = bool
  }))
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

# Per distinct instance type in the fleet: whether it's a GPU type (nonzero .gpus) and which AZs
# offer it. Not every type is offered in every AZ (g7e is NOT in us-east-1a, where the default
# subnet[0] lands), so each node lands in a subnet whose AZ offers its type — no hardcoded AZ,
# self-corrects with AWS.
data "aws_ec2_instance_type" "flex" {
  for_each      = local.flex_instance_types
  instance_type = each.key
}

data "aws_ec2_instance_type_offerings" "flex" {
  for_each      = local.flex_instance_types
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [each.key]
  }
}

data "aws_subnets" "flex_az" {
  for_each = local.flex_instance_types

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }

  # Default subnets only in AZs that actually offer this instance type.
  filter {
    name   = "availability-zone"
    values = data.aws_ec2_instance_type_offerings.flex[each.key].locations
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

  # Distinct instance types across the fleet — drives the per-type data-source lookups above.
  flex_instance_types = toset([for n in values(var.flex_nodes) : n.instance_type])
  # The fleet as an ordered list (sorted by pod CIDR key) so count.index is stable across plans.
  flex_node_list = [for cidr in sort(keys(var.flex_nodes)) : {
    pod_cidr               = cidr
    instance_type          = var.flex_nodes[cidr].instance_type
    termination_protection = var.flex_nodes[cidr].termination_protection
  }]

  # One cloud-init per fleet entry, indexed by count.index (matches aws_instance.this). config.json +
  # the CNI conflist are rendered by jsonencode (proper escaping for the CA cert), base64'd, and
  # decoded in the cloud-init — no fragile heredoc interpolation. Nodes differ only by pod CIDR (its
  # bridge-CNI range + advertised labels) and instance type (the hostname suffix + GPU label).
  cloud_init = [
    for node in local.flex_node_list : templatefile("${path.module}/cloud-init.sh.tftpl", {
      afn_url = local.afn_url
      # Sanitize the type's dot to a dash for a valid hostname suffix: g7e.2xlarge -> g7e-2xlarge.
      instance_type_label = replace(node.instance_type, ".", "-")
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
          # GPU-family nodes (the type reports nonzero GPUs) also advertise p6m.dev/node-type=gpu-shared.
          labels = merge(
            {
              "flex.azure.com/pod-network" = split("/", node.pod_cidr)[0]
              "flex.azure.com/pod-prefix"  = split("/", node.pod_cidr)[1]
            },
            length(data.aws_ec2_instance_type.flex[node.instance_type].gpus) > 0 ? { "p6m.dev/node-type" = "gpu-shared" } : {},
          )
          taints = ["flexnode=true:NoSchedule"]
        }
      }))
      cni_conf_b64 = base64encode(jsonencode({
        cniVersion = "1.0.0"
        name       = "flexnet"
        plugins = [
          {
            type      = "bridge"
            bridge    = "cni0"
            isGateway = true
            # SNAT pod egress to the node IP so pod->internet traverses the IGW (which only NATs the
            # node's own IP, not the 172.20.x pod IP). Was false to preserve pod-IP identity across
            # the WAN for cross-cloud pod-to-pod, but that's abandoned; service/DNS traffic is already
            # SNAT'd by kube-proxy, so this only newly affects internet egress.
            ipMasq      = true
            hairpinMode = true
            ipam = {
              type   = "host-local"
              ranges = [[{ subnet = node.pod_cidr }]]
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

resource "aws_instance" "this" {
  count = length(local.flex_node_list)
  ami   = data.aws_ami.ubuntu.id
  # Per-node instance type from var.flex_nodes (fleet ordered by pod CIDR). Each node is placed in a
  # subnet whose AZ offers its type (e.g. g7e is unavailable in us-east-1a).
  instance_type           = local.flex_node_list[count.index].instance_type
  disable_api_termination = local.flex_node_list[count.index].termination_protection
  key_name                = aws_key_pair.this.key_name
  subnet_id              = sort(data.aws_subnets.flex_az[local.flex_node_list[count.index].instance_type].ids)[0]
  vpc_security_group_ids = [aws_security_group.this.id]

  # Bootstrap the AKS Flex Node via cloud-init; a config change (pod CIDR / type / hostname) rebuilds
  # the instance. The primary ENI is auto-created per instance, so the private IP + node name change
  # on each rebuild (leaving a stale NotReady Node to clean up).
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

output "public_ips" {
  description = "Auto-assigned (ephemeral) public IPs of the flex instances — EIPs were removed, so these change on each rebuild."
  value       = aws_instance.this[*].public_ip
}

output "private_ips" {
  value = aws_instance.this[*].private_ip
}

output "subnet_ids" {
  description = "Distinct subnets the flex instances landed in (nodes of different instance types can be in different AZs — e.g. the GPU node). The TGW VPC attachment must cover all of them so the control plane can reach every node's kubelet (exec/logs)."
  value       = distinct([for i in aws_instance.this : i.subnet_id])
}
