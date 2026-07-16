# kubecompose

A multi-node Kubernetes cluster — minikube's docker-driver nodes — **reverse-engineered
into plain `docker compose`**, with no `kubeadm` and no `minikube` in the boot path.

`minikube start` normally runs kubeadm inside a node container to bootstrap the
control plane, then applies workloads imperatively. kubecompose throws that away:
a multi-stage Dockerfile bakes everything the tool would mint (static-pod manifests,
generated PKI, kubeconfigs, systemd units, addons) into node images, and `docker
compose up` is the only command. Tear it down and the next `up` is a brand-new
cluster (etcd lives on tmpfs, CAs are re-minted every image build).

It started as a teardown of how these clusters actually work — every cert,
kubeconfig, manifest, systemd unit, and volume laid out on disk and wired up by
hand — and grew into a networking lab. (A kind variant lived here too; see git
history.)

## Topology

```
minikube      192.168.49.2 + 192.168.58.3   control plane, dual-homed  ─┬ bridge "minikube-cloud"
              (+ .49.254/.58.254, claimed by the in-cluster ToR)        │
minikube-m02  192.168.49.3                  worker                     ─┘
minikube-m03  192.168.58.2                  worker                     ── bridge "minikube-onprem"
```

> **Lab BGP is parked.** The in-cluster "route server" that healed the
> cross-bridge node (an FRR Deployment claiming `.254` on both bridges, with
> per-node speakers peering it) has been removed from `charts/bgp` —
> the chart is currently AKS-shaped (speakers → an external Azure Route Server,
> pod CIDR from NodeNetworkConfig). The docker-lab route server will be reworked
> later. The description below reflects the parked design.

The "top-of-rack router" was a cluster workload: the built-in route server —
an FRR Deployment pinned to the control-plane node by the AKS-style system
label its kubelet self-sets (`--node-labels=kubernetes.azure.com/mode=system`).
The node sits on both bridges; the route-server pod claimed `.254` secondary
addresses on its interfaces and the kernel forwarded between the legs.

m03 is the "on-prem" node — deliberately on a **second docker bridge**, the
WAN between cloud and on-prem played by docker itself. Docker's inter-bridge
isolation is asymmetric (NAT-like: node-initiated egress works, nothing can dial
in), which used to make m03 a zombie — Ready, running pods, but no pod network
and no `kubectl logs/exec`. The fix is the real-world pattern: every node runs
an FRR speaker (AS 65001) that peers eBGP with the ToR; pod and cross-bridge
node traffic hops through the ToR's dual-homed node, and every hop is
intra-bridge, so the isolation never applies.

## Layout

```
minikube/
  Dockerfile            multi-stage: base (kicbase + binaries + CNI fix)
                        -> pki (gen-pki.sh runs ONCE; both images share one CA)
                        -> kubelet (generic worker: runtime chain, kube-proxy static
                           pod, bootstrap-token kubeconfig; no signing keys)
                        -> full (control plane: CP manifests, full PKI, apply-addons)
  gen-pki.sh            all CAs, certs, kubeconfigs, bootstrap token — at image build
  docker-compose.yml    4 services: minikube (full), m02 + m03 (kubelet), frr
  .env                  central knobs (CILIUM=on|off)
  etc-kubernetes/       static-pod manifests (etcd, apiserver, cm, scheduler, kube-proxy)
  lib-systemd-system/   runtime-chain units: containerd -> dockerd -> cri-dockerd -> kubelet
  etc-systemd-system/   drop-ins + apply-addons oneshot
  systemd-wants/        .target.wants/ enablement symlinks
  addons/               applied once per boot: cilium (or kindnet), coredns, storage,
                        RBAC (cluster-admin, node bootstrap, kube-proxy), nginx canary
  var-lib-kubelet/      kubelet config
charts/bgp/             Per-node BGP speaker for Kubernetes (AKS): a speaker DaemonSet
                        (kube-router pattern) that advertises each node's pod CIDR (from
                        NodeNetworkConfig) to an external route server (Azure Route Server).
                        values.yaml + values-ybor-playground.yaml (the AKS profile).
                        NOTE: the in-cluster route server for the docker lab was removed
                        pending a rethink — see "Networking lab" below.
Makefile                make minikube | make clean
```

## Usage

```sh
make minikube      # build node images + docker compose up + extract kubeconfig
make clean         # down -v --remove-orphans (containers, networks, volumes)

kubectl --kubeconfig=minikube/kubeconfig get nodes            # host access via 127.0.0.1:8443
CILIUM=off make minikube                                      # boot on kindnet instead

# bgp chart is AKS-only right now; deploy to a real cluster by hand:
helm upgrade --install bgp charts/bgp -n kube-system \
  -f charts/bgp/values-ybor-playground.yaml --kubeconfig <aks-kubeconfig>
kubectl --kubeconfig=minikube/kubeconfig logs -l app=nginx -c dump-iptables   # node iptables
```

## How it boots (no kubeadm, no minikube)

- **Runtime chain** — systemd (PID 1) starts `containerd → dockerd → cri-dockerd →
  kubelet`, all units + enablement symlinks baked from this repo. kicbase ships
  kubelet/cri-docker disabled; minikube enables them imperatively — we bake the
  `.wants/` symlinks instead.
- **Control plane** — etcd, apiserver, controller-manager, scheduler are static
  pods launched off build-generated certs. etcd's data dir is tmpfs: every `up`
  is a clean DB. kube-proxy is also a static pod, on **every** node, with its own
  `CN=system:kube-proxy` cert (bound to `system:node-proxier` by addon RBAC).
- **Workers join by TLS bootstrapping** — the worker image is node-agnostic:
  hostname from compose, IP auto-detected, and a bootstrap-token kubeconfig
  (token minted by gen-pki, honored via apiserver `--token-auth-file`). The
  kubelet CSRs for its client cert; addon RBAC auto-approves; kcm signs with the
  cluster CA. Adding a node = ~45 compose-only lines.
- **Addons** — a fresh etcd has none of the workloads or RBAC kubeadm/minikube
  would have created. `apply-addons.service` waits for `/healthz` then applies
  `/addons` as super-admin (`system:masters`, works before any RBAC exists).
  `CILIUM=off` (env/.env) swaps cilium for a kindnet fallback so the cluster
  stays healthy without it.
- **CNI ordering** — the Dockerfile deletes kicbase's leftover podman bridge CNI
  conf, so early pods stay Pending until the CNI is ready instead of racing onto
  the wrong network.

## Networking lab: native routing + BGP

cilium runs `routing-mode: native` (no vxlan) and stays out of BGP entirely.
Routing is the **bgp chart** (`charts/bgp`, helm-delivered by
the Makefile rather than baked into the image, so BGP knobs iterate against a
running cluster) — the kube-router pattern, and the AKS/EKS-constrained model:
nothing touches the node's systemd; a hostNetwork FRR speaker per node
(the `-speaker` DaemonSet) speaks eBGP with the route server. Each side is
fully dynamic:

- **node → ToR**: bgpd redistributes the kernel podCIDR route cilium programs
  (`10.244.X.0/24 via cilium_host`), filtered **structurally**: a route-map
  matching `interface cilium_host` plus a prefix-length guard (`ge 8 le 30`
  kills the default route and the CNI's host /32s). No podCIDR discovery, no
  API calls, no RBAC — the podCIDR is *defined* as "the aggregate route on
  the CNI's interface", so any cluster CIDR and any allocator works. (Earlier
  iterations fetched the CIDR from the allocator's API object — kcm's
  `node.spec.podCIDR` is a lie under cilium's cluster-pool IPAM, whose truth
  is `CiliumNode`; AKS's delegated-plugin keeps it in Azure's
  `NodeNetworkConfig` — until the route-map made the question moot.) No
  hostname selectors, no per-node CRs. (cilium's own BGP Control Plane was
  dropped: it advertises but never installs received routes — half the job.)
- **ToR → node**: zebra *installs* what it learns — every other podCIDR plus
  both bridge subnets (`redistribute connected` on the ToR), so cross-bridge
  kubelet reachability is learned, not hardcoded. A node's own subnet also
  arrives but loses to the connected route (distance 0 vs 20).
- **ToR config is node-free**: `bgp listen range` accepts any node as a
  dynamic neighbor; `as-override` lets all nodes share AS 65001 without
  tripping eBGP loop detection. The only surviving convention: the ToR lives
  at `.254` of each node's /24 (rendered into frr.conf at pod start from the
  downward-API host IP).

This heals even a node that boots broken: kubelet→apiserver is node-initiated
egress (docker's isolation is asymmetric), hostNetwork pods need no CNI, and
the image pull is internet egress — so the FRR pod lands, BGP converges, and
the node routes itself out of the hole.

Result, verified every boot by the **nginx canary DaemonSet**: an init container
nslookups `kubernetes.default` through cluster DNS — a node with a broken
network path shows `Init:Error`/`Init:CrashLoopBackOff` (red in k9s) until the
path heals. A second init container dumps the node's iptables
(`-c dump-iptables`) for datapath spelunking.

Findings bank from getting here: hostPort works under kindnet (portmap chained)
but silently no-ops on stock minikube cilium; docker inter-bridge isolation is
initiation-asymmetric; vxlan dies across it because encap replies are new outer
flows (fixable with a pinned `tunnel-source-port-range`, the untaken Avenue A);
`node.spec.podCIDR` is a lie under cluster-pool IPAM (kcm keeps allocating it,
cilium ignores it) and absent entirely under AKS's delegated-plugin, where the
per-node overlay /24 hides in `NodeNetworkConfig.status.networkContainers[0]
.primaryIP`; eBGP third-party next-hop means same-bridge pod traffic skips the
ToR hop for free.

## Credentials / PKI

Generated at image build by `minikube/gen-pki.sh` — minikubeCA / front-proxy-ca /
etcd-ca, every leaf cert with the same subjects/SANs/EKUs `minikube start` would
produce, the ServiceAccount keypair, all kubeconfigs, and the worker bootstrap
token. The PKI stage runs once and both node images copy from it (one CA — build
the services together; a lone `--no-cache` rebuild would mint a divergent CA).
The worker image carries no signing keys and no admin identities. **No secret
material exists in the repo**, and every rebuild is a key rotation. Keys live
only in local images — don't push them to a registry. `make minikube` extracts
the host-access kubeconfig to `minikube/kubeconfig` (gitignored).
