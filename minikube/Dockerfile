# kubecompose node images — kubeadm-less, baked, multi-stage.
#
#   base    kicbase + k8s binaries (dl.k8s.io, checksum-verified) + CNI-race fix
#   pki     runs gen-pki.sh ONCE: cluster CAs, every cert/kubeconfig, bootstrap token.
#           Both node images copy from this single stage, so they share one CA. Build the
#           compose services together — an isolated --no-cache rebuild of one service would
#           mint a divergent CA and break node auth.
#   kubelet the generic WORKER image: runtime chain (containerd->dockerd->cri-dockerd->kubelet),
#           kube-proxy static pod, cluster CA + bootstrap-token kubeconfig. Node-agnostic —
#           hostname comes from compose, node IP is auto-detected, and the kubelet earns its
#           client cert via standard TLS bootstrapping (CSR auto-approved by addon RBAC).
#           Deliberately NO private keys: no ca.key, no sa.key, no super-admin.
#   full    the CONTROL-PLANE image: kubelet stage + control-plane static-pod manifests,
#           the full PKI (kcm needs ca.key to sign worker CSRs), static kubelet identity,
#           and the apply-addons oneshot.
#
# Keys live only in local images; don't push them to a registry.

# ---------- base ----------
FROM gcr.io/k8s-minikube/kicbase:v0.0.50@sha256:eb4fec00e8ad70adf8e6436f195cc429825ffb85f95afcdb5d8d9deb576f3e93 AS base

ARG K8S_VERSION=v1.35.1
ARG TARGETARCH
RUN set -eux; \
    d=/var/lib/minikube/binaries/${K8S_VERSION}; mkdir -p "$d"; \
    base=https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${TARGETARCH}; \
    for bin in kubelet kubectl; do \
      curl -fsSL -o "$d/$bin" "$base/$bin"; \
      echo "$(curl -fsSL "$base/$bin.sha256")  $d/$bin" | sha256sum -c -; \
      chmod +x "$d/$bin"; \
    done

# kicbase ships a leftover podman bridge CNI conf. cri-dockerd picks the alphabetically-first
# conflist, racing early pods onto the 10.88.0.0/16 podman bridge before cilium writes its
# own. With no CNI present, pods correctly stay Pending until cilium is ready.
RUN rm /etc/cni/net.d/87-podman-bridge.conflist

# kicbase's own entrypoint runs systemd (/sbin/init) as PID 1 — unchanged.
ENTRYPOINT ["/usr/local/bin/entrypoint", "/sbin/init"]

# ---------- pki (single source of truth for all key material) ----------
FROM base AS pki
COPY gen-pki.sh /usr/local/bin/gen-pki.sh
RUN bash /usr/local/bin/gen-pki.sh

# ---------- kubelet (generic worker) ----------
FROM base AS kubelet

# systemd: runtime chain + kubelet units, generic drop-ins, enablement symlinks
# (COPY preserves symlinks within a dir; kicbase ships kubelet + cri-docker disabled)
COPY lib-systemd-system/ /lib/systemd/system/
COPY etc-systemd-system/cri-docker.service.d/10-cni.conf /etc/systemd/system/cri-docker.service.d/10-cni.conf
COPY etc-systemd-system/kubelet.service.d/10-kubelet.conf /etc/systemd/system/kubelet.service.d/10-kubelet.conf
COPY systemd-wants/multi-user.target.wants/ /etc/systemd/system/multi-user.target.wants/
COPY systemd-wants/sockets.target.wants/ /etc/systemd/system/sockets.target.wants/

# kubelet config + the one static pod every node runs: kube-proxy
COPY var-lib-kubelet/config.yaml /var/lib/kubelet/config.yaml
COPY etc-kubernetes/manifests/kube-proxy.yaml /etc/kubernetes/manifests/kube-proxy.yaml
COPY etc-kubernetes/kube-proxy/config.conf /etc/kubernetes/kube-proxy/config.conf

# worker credentials: cluster CA (public), the bootstrap-token kubeconfig, and kube-proxy's
# cert kubeconfig (system:node-proxier scope). No signing keys, no admin identities.
COPY --from=pki /var/lib/minikube/certs/ca.crt /var/lib/minikube/certs/ca.crt
COPY --from=pki /etc/kubernetes/bootstrap-kubelet.conf /etc/kubernetes/bootstrap-kubelet.conf
COPY --from=pki /etc/kubernetes/kube-proxy.conf /etc/kubernetes/kube-proxy.conf

# ---------- full (control plane) ----------
FROM kubelet AS full

# control-plane static-pod manifests (+ addons dir scooped from the node, kube-proxy config
# already present from the kubelet stage)
COPY etc-kubernetes/ /etc/kubernetes/

# complete PKI: kcm signs worker CSRs with ca.key; apiserver needs its serving/etcd/sa keys;
# includes the static kubelet client identity + bootstrap token file
COPY --from=pki /var/lib/minikube/certs/ /var/lib/minikube/certs/
COPY --from=pki /etc/kubernetes/admin.conf /etc/kubernetes/super-admin.conf /etc/kubernetes/controller-manager.conf /etc/kubernetes/scheduler.conf /etc/kubernetes/kubelet.conf /etc/kubernetes/
COPY --from=pki /var/lib/minikube/host.kubeconfig /var/lib/minikube/host.kubeconfig

# control-plane kubelet: static identity, no bootstrap (this kubelet launches the apiserver)
COPY etc-systemd-system/kubelet.service.d/20-control-plane.conf /etc/systemd/system/kubelet.service.d/20-control-plane.conf

# addon apply oneshot (control plane only) + its enablement symlink
COPY etc-systemd-system/apply-addons.service /etc/systemd/system/apply-addons.service
RUN ln -s /etc/systemd/system/apply-addons.service /etc/systemd/system/multi-user.target.wants/apply-addons.service
COPY addons/ /addons/
