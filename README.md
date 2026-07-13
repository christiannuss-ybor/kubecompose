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
minikube      192.168.49.2   control plane        ─┐
minikube-m02  192.168.49.3   worker                ├ bridge "minikube"
                                                   │
frr           .49.254/.58.254 dual-homed router   ─┼ (FRR, eBGP AS 65000)
                                                   │
minikube-m03  192.168.58.2   worker               ─┘ bridge "minikube2"
```

m03 deliberately lives on a **second docker bridge**. Docker's inter-bridge
isolation is asymmetric (NAT-like: node-initiated egress works, nothing can dial
in), which used to make m03 a zombie — Ready, running pods, but no pod network
and no `kubectl logs/exec`. The fix is the real-world pattern: nodes speak BGP
(cilium's BGP Control Plane, AS 65001) to the dual-homed FRR "top-of-rack"
router; pod and cross-bridge node traffic hops through FRR, and every hop is
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
  frr/                  the router: daemons + frr.conf (eBGP, no policy, 3 node peers)
  addons/               applied once per boot: cilium (or kindnet), coredns, storage,
                        RBAC (cluster-admin, node bootstrap, kube-proxy), nginx canary,
                        node-routes DaemonSet (static routes toward FRR)
  addons-bgp/           cilium BGPv2 CRs (applied with retry — operator registers CRDs late)
  var-lib-kubelet/      kubelet config
Makefile                make minikube | make clean
```

## Usage

```sh
make minikube    # build node images + docker compose up + extract kubeconfig
make clean       # down -v --remove-orphans (containers, networks, volumes)

kubectl --kubeconfig=minikube/kubeconfig get nodes            # host access via 127.0.0.1:8443
CILIUM=off make minikube                                      # boot on kindnet instead
docker exec frr vtysh -c 'show bgp summary'                   # BGP sessions
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

cilium runs `routing-mode: native` (no vxlan) with `enable-bgp-control-plane`.
Each node advertises its podCIDR over eBGP to FRR (`addons-bgp/`); FRR's zebra
installs the routes and the kernel forwards between its two bridge legs. Nodes
carry static routes toward FRR for the pod /16 and the *other* bridge's node
subnet — cilium's BGP advertises but never installs received routes, same
division of labor as servers pointing at their ToR.

The node routes are programmed by the **node-routes DaemonSet**
(`addons/node-routes.yaml`) — the AKS/EKS-constrained model: nothing touches
the node's systemd; a hostNetwork + `NET_ADMIN` pod reconciles the routes in
the host netns, like every cloud CNI ships its route programming. This works
even on a node that boots broken: kubelet→apiserver is node-initiated egress
(docker's isolation is asymmetric), hostNetwork pods need no CNI, and the
image pull is internet egress — so the pod lands, programs routes, and the
node heals itself.

Result, verified every boot by the **nginx canary DaemonSet**: an init container
nslookups `kubernetes.default` through cluster DNS — a node with a broken
network path shows `Init:Error`/`Init:CrashLoopBackOff` (red in k9s) until the
path heals. A second init container dumps the node's iptables
(`-c dump-iptables`) for datapath spelunking.

Findings bank from getting here: hostPort works under kindnet (portmap chained)
but silently no-ops on stock minikube cilium; docker inter-bridge isolation is
initiation-asymmetric; vxlan dies across it because encap replies are new outer
flows (fixable with a pinned `tunnel-source-port-range`, the untaken Avenue A).

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
