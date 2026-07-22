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
