# kubecompose

A local Kubernetes cluster — minikube's docker-driver node — **reverse-engineered
into plain `docker compose`**, with no `kubeadm` and no `minikube` in the boot path.

`minikube start` normally runs kubeadm inside a node container to bootstrap the
control plane, then applies workloads imperatively. kubecompose throws that away:
a Dockerfile bakes everything the tool would mint (static-pod manifests, generated
PKI, kubeconfigs, systemd units, addons) into the node image, and `docker compose
up` is the only command. Tear it down and the next `up` is a brand-new cluster
(etcd lives on tmpfs, CAs are re-minted every image build).

It started as a teardown of how these clusters actually work — every cert,
kubeconfig, manifest, systemd unit, and volume laid out on disk and wired up by
hand. (A kind variant lived here too; see git history.)

## Layout

```
minikube/
  Dockerfile            FROM kicbase: COPYs everything below, downloads kubelet/kubectl
                        from dl.k8s.io (checksum-verified), runs gen-pki.sh
  gen-pki.sh            generates all CAs, certs, and kubeconfigs at image build
  docker-compose.yml    the node service: runtime volumes, tmpfs etcd, network, port 8443
  etc-kubernetes/       static-pod manifests (etcd, apiserver, cm, scheduler, kube-proxy)
  lib-systemd-system/   runtime-chain units: containerd -> dockerd -> cri-dockerd -> kubelet
  etc-systemd-system/   drop-ins + the apply-addons oneshot
  systemd-wants/        .target.wants/ enablement symlinks
  addons/               applied once per boot: cilium, coredns, storage, RBAC,
                        prometheus + node-exporter
  var-lib-kubelet/      kubelet config
Makefile                make minikube | make clean
```

## Usage

```sh
make minikube    # build the node image + docker compose up + extract kubeconfig
make clean       # down -v --remove-orphans (containers, network, volumes)

kubectl --kubeconfig=minikube/kubeconfig get pods -A   # host access via 127.0.0.1:8443
kubectl --kubeconfig=minikube/kubeconfig -n monitoring port-forward svc/prometheus 9090
```

## How it boots (no kubeadm, no minikube)

- **Runtime chain** — systemd (PID 1) starts `containerd → dockerd → cri-dockerd →
  kubelet`, all units + enablement symlinks baked from this repo. kicbase ships
  kubelet/cri-docker disabled; minikube enables them imperatively — we bake the
  `.wants/` symlinks instead.
- **Control plane** — etcd, apiserver, controller-manager, scheduler, and
  kube-proxy are static pods in `etc-kubernetes/manifests/`, launched by kubelet
  off build-generated certs. etcd's data dir is tmpfs: every `up` is a clean DB.
- **Addons** — a fresh etcd has none of the workloads or RBAC kubeadm/minikube
  would have created. `apply-addons.service` waits for `/healthz` then
  `kubectl apply -f /addons/` as super-admin (`system:masters`, works before any
  RBAC exists), restoring cilium (CNI), coredns, storage, the
  `kubeadm:cluster-admins` binding, and prometheus + node-exporter.
- **CNI ordering** — the Dockerfile deletes kicbase's leftover podman bridge CNI
  conf, so early pods stay Pending until cilium is ready instead of racing onto
  the wrong network.
- **Monitoring** — prometheus scrapes only cluster-DNS names (coredns, the
  apiserver via SA token + generated CA, kubelet, node-exporter), so a green
  target page proves DNS, service routing, and the auth chain every boot.

## Credentials / PKI

Generated at image build by `minikube/gen-pki.sh` — minikubeCA / front-proxy-ca /
etcd-ca, every leaf cert with the same subjects/SANs/EKUs `minikube start` would
produce, the ServiceAccount keypair, and all kubeconfigs. **No secret material
exists in the repo**, and every rebuild is a key rotation. Keys live only in the
local image — don't push the image to a registry. `make minikube` extracts the
host-access kubeconfig to `minikube/kubeconfig` (gitignored).
