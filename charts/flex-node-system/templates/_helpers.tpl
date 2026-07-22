{{/*
FRR relay enablement — the chart's "fiddle bits".

The FRR relay only makes sense when this cluster has an Azure Route Server to eBGP-peer. That is
NOT the default: on-prem / ExpressRoute clusters exchange routes natively and have no Route Server
(see the a1p-apps-dev-eastus profile), so `asn` and `routeServer.*` are EMPTY by default and the
system-node pod runs CoreDNS only.

Populate `asn` + at least one `routeServer.addresses[]` (as values-ybor-playground.yaml does) to
turn the relay on: the FRR container, its pod-CIDR discovery init + config render, the headless
:179 Service, and the NodeNetworkConfig RBAC all appear together. Emits "true" when enabled, else
empty (falsy) — use as `{{- if (include "flex-node-system.frrEnabled" .) }}`.
*/}}
{{- define "flex-node-system.frrEnabled" -}}
{{- if and .Values.asn (gt (len (.Values.routeServer.addresses | default list)) 0) -}}
true
{{- end -}}
{{- end -}}

{{/*
flex CoreDNS Service VIP (the flex nodes' --cluster-dns).

Override with system.coredns.clusterIP. When empty, derive it from the cluster's kube-dns Service
ClusterIP by appending "0" (10.0.0.10 -> 10.0.0.100) — a stable free IP in the service CIDR. The
lookup runs at install/upgrade time; `helm template` / `--dry-run` have no cluster and return empty,
so set the override (or --set) to render offline. Emits the IP or empty (callers `required` it).
*/}}
{{- define "flex-node-system.dnsClusterIP" -}}
{{- if .Values.system.coredns.clusterIP -}}
{{- .Values.system.coredns.clusterIP -}}
{{- else -}}
{{- with (dig "spec" "clusterIP" "" (lookup "v1" "Service" "kube-system" "kube-dns")) -}}
{{- printf "%s0" . -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
kube-proxy clusterCIDR — the AKS pod-CIDR aggregate (kube-proxy's only consumer of it; it decides
which Service traffic to masquerade: flex pods at 172.20.x fall OUTSIDE it -> SNAT'd to the node IP).
Override with kubeProxy.clusterCidr. When empty, derive it from any node's NodeNetworkConfig —
status.networkContainers[0].subnetAddressSpace (e.g. 192.168.0.0/16), taking any NNC/container. The
lookup runs at install/upgrade; `helm template` / `--dry-run` have no cluster and derive nothing.
Emits the override or derived CIDR, else empty — the caller defaults empty to 192.168.0.0/16 (the AKS
default pod CIDR), so it never fails and still renders offline.
*/}}
{{- define "flex-node-system.clusterCidr" -}}
{{- if .Values.kubeProxy.clusterCidr -}}
{{- .Values.kubeProxy.clusterCidr -}}
{{- else -}}
{{- $items := dig "items" (list) (lookup "acn.azure.com/v1alpha" "NodeNetworkConfig" "kube-system" "") -}}
{{- if $items -}}
{{- $ncs := dig "status" "networkContainers" (list) (index $items 0) -}}
{{- if $ncs -}}
{{- dig "subnetAddressSpace" "" (index $ncs 0) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
