# kubecompose minikube node — kubeadm-less, baked.
# Everything the tool would mint at `minikube start` (static-pod manifests, PKI, kubeconfigs,
# systemd units + enablement, kubelet binaries, addons) is COPYed into the image instead of
# bind-mounted at runtime. The image is self-contained; docker-compose only supplies mutable
# runtime state (named volumes for the container runtime + kubelet, tmpfs etcd) and the network.
#
# NOTE: the COPY sources include cluster PKI/kubeconfigs that are gitignored (never pushed).
# They must exist locally at build time — regenerate by scooping a fresh cluster (see README).
FROM gcr.io/k8s-minikube/kicbase:v0.0.50@sha256:eb4fec00e8ad70adf8e6436f195cc429825ffb85f95afcdb5d8d9deb576f3e93

# --- control-plane config + PKI (static-pod manifests, certs, kubeconfigs, addons dir) ---
COPY etc-kubernetes/ /etc/kubernetes/

# --- minikube certs + kubeconfig ---
COPY var-lib-minikube/certs/ /var/lib/minikube/certs/
COPY var-lib-minikube/kubeconfig /var/lib/minikube/kubeconfig

# --- kubelet + kubectl: kicbase ships no k8s binaries; minikube downloads them at `minikube
#     start`. We do the same at build time from dl.k8s.io (checksum-verified) instead of
#     committing 100MB+ to the repo. kubeadm omitted — kubeadm-less, nothing invokes it.
#     TARGETARCH is set automatically by buildkit (arm64/amd64). ---
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

# --- kubelet bring-up files (seed the /var/lib/kubelet volume) ---
COPY var-lib-kubelet/config.yaml /var/lib/kubelet/config.yaml
COPY var-lib-kubelet/pki/ /var/lib/kubelet/pki/

# --- systemd: runtime-chain + kubelet units, their drop-ins, and apply-addons oneshot ---
COPY lib-systemd-system/ /lib/systemd/system/
COPY etc-systemd-system/ /etc/systemd/system/

# --- unit enablement: symlinks in *.target.wants/ (COPY preserves symlinks within a dir).
#     kicbase ships kubelet + cri-docker disabled; these enable them + apply-addons at boot. ---
COPY systemd-wants/multi-user.target.wants/ /etc/systemd/system/multi-user.target.wants/
COPY systemd-wants/sockets.target.wants/ /etc/systemd/system/sockets.target.wants/

# --- addons applied once by apply-addons.service (cilium, coredns, storage, cluster-admin RBAC) ---
COPY addons/ /addons/

# kicbase's own entrypoint runs systemd (/sbin/init) as PID 1 — unchanged.
ENTRYPOINT ["/usr/local/bin/entrypoint", "/sbin/init"]
