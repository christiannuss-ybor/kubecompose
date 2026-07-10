#!/bin/bash
# Static routes toward the FRR router (192.168.<bridge>.254) — run on every node by
# node-routes.service. Cilium's BGP Control Plane advertises podCIDRs to FRR but does not
# install routes received from it (documented limitation), so the node side is static —
# exactly like pointing servers at their top-of-rack router.
set -euo pipefail

ip4=$(ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1)
subnet=$(echo "$ip4" | cut -d. -f1-3)
frr="$subnet.254"

# pod traffic: anything in the cluster pod range not on this node goes via FRR
# (the node's own podCIDR is a more-specific route through cilium and wins)
ip route replace 10.244.0.0/16 via "$frr" dev eth0

# node-subnet reachability across bridges (kubelet API, cilium health): route the OTHER
# bridge via FRR. Never touch our own subnet — that would clobber the connected route.
for other in 192.168.49.0/24 192.168.58.0/24; do
  case "$other" in
    "$subnet".0/24) ;;  # own subnet: skip
    *) ip route replace "$other" via "$frr" dev eth0 ;;
  esac
done

echo "node-routes: pod /16 and foreign node subnets via $frr"
ip route show | grep -E '10\.244|192\.168\.(49|58)'
