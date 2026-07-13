# Cross-Cloud Pod Reachability

Making an AKS pod IP reachable from a machine on a **different network**, across a
peering connection — the gap a plain peering can't cross on its own.

A peering connection routes the two sides' *network* address spaces (node IPs,
VM IPs) to each other. It does **not** carry the Kubernetes **pod overlay** — pod
CIDRs aren't part of the VNet address space and the fabric has no route to them. So
a remote host can reach an AKS *node* but not a *pod*. We close that with BGP: an
in-cluster speaker advertises each node's pod CIDR, Azure Route Server injects it
into the fabric and hands it to the edge gateway, and it propagates across the
peering to the remote side.

```
CROSS-CLOUD POD REACHABILITY  —  remote host  ⇄  AKS pod overlay            [proven: 3/3, 72ms]

        Azure                          ┌── Peering Connection ──┐            Remote site
                                       │         (BGP)          │
 ┌──────────────────────────────┐      │                        │    ┌────────────────────────────┐
 │ VNet 10.224.0.0/12           │      ▼                        ▼    │ Remote net 172.31.0.0/16   │
 │                              │                                    │                            │
 │  AKS node                    │                                    │  Remote host               │
 │  10.224.0.108 ◀── Gateway ═══╪═══════ peering carries pkts ═══════╪═══ Gateway ◀── 172.31.6.104│
 │   │ cilium       AS65515     │                                    │    AS64512                 │
 │   ▼        (edge, BGP)       │                                    │                            │
 │  pod 192.168.6.11            │                                    │                            │
 │  (192.168.6.0/24)            │                                    │                            │
 └──────────────────────────────┘                                    └────────────────────────────┘

 DATA PLANE (packet):  host ─▶ Gateway ─▶ peering ─▶ Azure Gateway ─▶ node ─▶ cilium ─▶ pod


 CONTROL PLANE  —  how 192.168.6.0/24 becomes routable across the peering (BGP, hop by hop):

   FRR speaker              Azure Route Server        Azure Gateway        Remote Gateway    Remote net
   (AKS pod, AS65001)  ──▶  (AS65515)            ──▶  (AS65515)      ──▶   (AS64512)   ──▶   route table
   advertises the node's    injects into VNet         re-advertises        learns via        192.168.6.0/24
   podCIDR 192.168.6.0/24   fabric + branch-to-       192.168.6.0/24       BGP, auto-        ─▶ Gateway
                            branch to the gateway     across the peering   propagates

 Self-hosted: FRR speaker + kubelet/CNI.   Managed (Azure-only): Route Server does the fabric injection.
```

## Why Route Server

The BGP speaking is self-hostable (FRR/BIRD/OpenBGPD in a pod). What is **not**
self-hostable is injecting a route into the Azure fabric — only a first-party
component (Azure Route Server, or an ExpressRoute gateway) can program the VNet's
underlay so it forwards to a prefix it wasn't natively told about. Route Server is
the dynamic, BGP-driven way to do that; the static alternative is hand-maintained
UDRs.

## PoC note

This PoC realizes the **Peering Connection** with an Azure ↔ AWS site-to-site VPN,
because the environment can't stand up a real ExpressRoute circuit. The architecture
is identical over ExpressRoute (or an Equinix cross-connect) — only the transport
underneath changes. VPN-specific artifacts (IPsec overhead, ~1400 PMTU, APIPA BGP
addressing) are properties of the stand-in, not of the design; a production
ExpressRoute peering would differ there.
