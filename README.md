# kubecompose

Local Kubernetes clusters — kind and minikube — **reverse-engineered into plain
`docker compose`**, with no `kubeadm` in the boot path.

Both tools normally run `kubeadm init` inside a node container to bootstrap the
control plane. kubecompose throws that away: the node image runs `systemd`, and
the entire cluster comes up from **static-pod manifests + systemd units + one
addon-apply oneshot**, all mounted from this repo. `docker compose up` is the
only command. Tear it down and the next `up` is a brand-new cluster (etcd lives
on tmpfs).

It's a teardown of how these clusters actually work — every cert, kubeconfig,
manifest, systemd unit, and volume the tools mint, laid out on disk and wired up
by hand.

## Layout

```
kind/         kind v0.31 (k8s 1.35, containerd) reverse-engineered
minikube/     minikube v1.38 (k8s 1.35, docker driver, cilium CNI) reverse-engineered
Makefile      make kind | make minikube | make clean
```

Each stack directory holds:

| Path | What it is |
|------|-----------|
| `docker-compose.yml` | the single node service — a 1:1 distillation of the container the tool created (image, privileged, cgroups, tmpfs, network, volumes) |
| `etc-kubernetes/` | control-plane source of truth: static-pod `manifests/`, kubeconfigs, `addons/` |
| `lib-systemd-system/`, `etc-systemd-system/` | the systemd units that bring up the runtime + kubelet, mounted `:ro` so this repo is authoritative |
| `systemd-wants/` | `.target.wants/` enablement symlinks (mounted as a dir so systemd honors them) |
| `addons/` | what a fresh etcd lacks — CNI, coredns, storage, RBAC — applied once by `apply-addons.service` |
| `var-lib-*` | kubelet config + PKI + (minikube) the downloaded k8s binaries |

## Usage

```sh
make kind        # docker compose up the kind stack
make minikube    # docker compose up the minikube stack
make clean       # down -v --remove-orphans both (containers, networks, volumes)
```

`kubectl` against a running stack:

```sh
# minikube publishes the apiserver on a stable 127.0.0.1:8443
kubectl --kubeconfig=minikube/kubeconfig get pods -A

# or from inside either node
docker exec kind  env KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A
docker exec minikube env KUBECONFIG=/etc/kubernetes/admin.conf \
  /var/lib/minikube/binaries/v1.35.1/kubectl get pods -A
```

## How each stack boots (no kubeadm)

- **Runtime** — `kind` runs `containerd` directly; `minikube` runs the
  `containerd → dockerd → cri-dockerd → kubelet` chain (docker driver). All are
  systemd units mounted from this repo.
- **Control plane** — etcd, apiserver, controller-manager, scheduler are static
  pods in `etc-kubernetes/manifests/`, launched by kubelet off mounted certs.
- **Networking** — `kind` uses kindnet (converted to a static pod); `minikube`
  uses **cilium** (kept as an addon: 2 DaemonSets + operator + CRDs). Both keep
  `kube-proxy` as a **static pod**.
- **Addons** — a fresh (tmpfs) etcd has none of the workloads or RBAC that
  `kubeadm`/the tool would have created. `apply-addons.service` waits for
  `/healthz`, then `kubectl apply -f /addons/` (as `super-admin.conf`, which is
  `system:masters` and works before any RBAC binding exists). `addons/` also
  ships the `kubeadm:cluster-admins` binding so `admin.conf` works too.
- **Ephemeral etcd** — etcd's data dir is a `tmpfs` mount, so every `up` is a
  clean cluster.

## Credentials / PKI

**minikube: generated at image build.** `minikube/gen-pki.sh` (run by the
Dockerfile) mints the full PKI — minikubeCA / front-proxy-ca / etcd-ca, every
leaf cert with the same subjects/SANs/EKUs `minikube start` would produce, the
ServiceAccount keypair, and all kubeconfigs. No secret material exists in the
repo, and every rebuild is a key rotation. Keys live only in the local image —
don't push the image to a registry. `make minikube` extracts the host-access
kubeconfig from the image to `minikube/kubeconfig` (gitignored).

**kind: still scooped.** The kind stack predates the build-time generator and
boots from PKI copied out of a real kind node (`docker cp` from a throwaway
`kind create cluster`). Converting it to the same Dockerfile + gen-pki pattern
is the obvious next step.

The per-file map of what lives where is in each stack's `docker-compose.yml`
and `minikube/Dockerfile`.
