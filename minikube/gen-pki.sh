#!/bin/bash
# Generates the cluster PKI + kubeconfigs at image build time (invoked by ./Dockerfile).
# Replaces the PKI that `minikube start` would mint — same CAs, subjects, SANs, and EKUs as
# the scooped originals — so nothing secret ever lives in the repo, and every image build is
# a key rotation. Keys land only in the image (local dev; don't push the image to a registry).
#
# Consumers (all inside the image):
#   /var/lib/minikube/certs/**            apiserver/etcd/controller-manager static pods
#   /etc/kubernetes/*.conf                kubelet, controller-manager, scheduler, kube-proxy
#                                         (super-admin), apply-addons (super-admin)
#   /var/lib/minikube/host.kubeconfig     extracted by `make minikube` for host kubectl
set -euo pipefail

C=/var/lib/minikube/certs
K=/etc/kubernetes
KUBECTL=/var/lib/minikube/binaries/v1.35.1/kubectl
NODE_IP=192.168.49.2
DAYS=3650
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$C/etcd" "$K"

# ca <path-prefix> <CN> [SAN]  — self-signed CA (minikube's CAs carry client+server EKUs,
# and front-proxy-ca/etcd-ca carry their own CN as a DNS SAN — replicated)
ca() {
  local out=$1 cn=$2 san=${3:-}
  openssl genrsa -out "$out.key" 2048 2>/dev/null
  local args=(-addext "basicConstraints=critical,CA:TRUE"
              -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign"
              -addext "extendedKeyUsage=clientAuth,serverAuth")
  [ -n "$san" ] && args+=(-addext "subjectAltName=$san")
  openssl req -x509 -new -key "$out.key" -subj "/CN=$cn" -days "$DAYS" -out "$out.crt" "${args[@]}"
}

# leaf <path-prefix> <subject> <ca-prefix> <eku> [SAN]
leaf() {
  local out=$1 subj=$2 signer=$3 eku=$4 san=${5:-}
  local ext="basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=$eku"
  [ -n "$san" ] && ext="$ext
subjectAltName=$san"
  openssl genrsa -out "$out.key" 2048 2>/dev/null
  openssl req -new -key "$out.key" -subj "$subj" |
    openssl x509 -req -CA "$signer.crt" -CAkey "$signer.key" -CAcreateserial \
      -days "$DAYS" -out "$out.crt" -extfile <(printf '%s\n' "$ext") 2>/dev/null
}

# ---- CAs ----
ca "$C/ca"             "minikubeCA"
ca "$C/front-proxy-ca" "front-proxy-ca" "DNS:front-proxy-ca"
ca "$C/etcd/ca"        "etcd-ca"        "DNS:etcd-ca"

# ---- ServiceAccount signing keypair ----
openssl genrsa -out "$C/sa.key" 2048 2>/dev/null
openssl rsa -in "$C/sa.key" -pubout -out "$C/sa.pub" 2>/dev/null

# ---- apiserver + clients ----
APISERVER_SANS="DNS:minikubeCA,DNS:control-plane.minikube.internal,DNS:minikube,DNS:kubernetes.default.svc.cluster.local,DNS:kubernetes.default.svc,DNS:kubernetes.default,DNS:kubernetes,DNS:localhost,IP:10.96.0.1,IP:127.0.0.1,IP:10.0.0.1,IP:$NODE_IP"
leaf "$C/apiserver"                "/O=system:masters/CN=minikube"                          "$C/ca" "serverAuth,clientAuth" "$APISERVER_SANS"
leaf "$C/apiserver-kubelet-client" "/O=kubeadm:cluster-admins/CN=kube-apiserver-kubelet-client" "$C/ca" "clientAuth"
leaf "$C/front-proxy-client"       "/CN=front-proxy-client"                                 "$C/front-proxy-ca" "clientAuth"

# ---- etcd ----
ETCD_SANS="DNS:localhost,DNS:minikube,IP:$NODE_IP,IP:127.0.0.1,IP:0:0:0:0:0:0:0:1"
leaf "$C/etcd/server"             "/CN=minikube"                    "$C/etcd/ca" "serverAuth,clientAuth" "$ETCD_SANS"
leaf "$C/etcd/peer"               "/CN=minikube"                    "$C/etcd/ca" "serverAuth,clientAuth" "$ETCD_SANS"
leaf "$C/etcd/healthcheck-client" "/CN=kube-etcd-healthcheck-client" "$C/etcd/ca" "clientAuth"
leaf "$C/apiserver-etcd-client"   "/CN=kube-apiserver-etcd-client"  "$C/etcd/ca" "clientAuth"

# ---- kubelet client identity (kubelet.conf points at this file; kept on an image path, NOT
#      the /var/lib/kubelet volume, so a rebuilt CA never fights a stale volume cert) ----
leaf "$TMP/kubelet-client" "/O=system:nodes/CN=system:node:minikube" "$C/ca" "clientAuth"
cat "$TMP/kubelet-client.crt" "$TMP/kubelet-client.key" > "$C/kubelet-client.pem"

# ---- kubeconfig identities (certs only needed transiently; embedded below) ----
leaf "$TMP/admin"              "/O=kubeadm:cluster-admins/CN=kubernetes-admin"     "$C/ca" "clientAuth"
leaf "$TMP/super-admin"        "/O=system:masters/CN=kubernetes-super-admin"       "$C/ca" "clientAuth"
leaf "$TMP/controller-manager" "/CN=system:kube-controller-manager"                "$C/ca" "clientAuth"
leaf "$TMP/scheduler"          "/CN=system:kube-scheduler"                         "$C/ca" "clientAuth"

# kubeconfig <file> <server> <user> <cert> <key> <embed>
kubeconfig() {
  local file=$1 server=$2 user=$3 cert=$4 key=$5 embed=$6
  "$KUBECTL" config --kubeconfig="$file" set-cluster mk \
    --server="$server" --certificate-authority="$C/ca.crt" --embed-certs=true >/dev/null
  "$KUBECTL" config --kubeconfig="$file" set-credentials "$user" \
    --client-certificate="$cert" --client-key="$key" --embed-certs="$embed" >/dev/null
  "$KUBECTL" config --kubeconfig="$file" set-context "$user@mk" --cluster=mk --user="$user" >/dev/null
  "$KUBECTL" config --kubeconfig="$file" use-context "$user@mk" >/dev/null
}

kubeconfig "$K/admin.conf"              "https://control-plane.minikube.internal:8443" kubernetes-admin              "$TMP/admin.crt"              "$TMP/admin.key"              true
kubeconfig "$K/super-admin.conf"        "https://control-plane.minikube.internal:8443" kubernetes-super-admin        "$TMP/super-admin.crt"        "$TMP/super-admin.key"        true
kubeconfig "$K/controller-manager.conf" "https://$NODE_IP:8443"                        system:kube-controller-manager "$TMP/controller-manager.crt" "$TMP/controller-manager.key" true
kubeconfig "$K/scheduler.conf"          "https://$NODE_IP:8443"                        system:kube-scheduler         "$TMP/scheduler.crt"          "$TMP/scheduler.key"          true
kubeconfig "$K/kubelet.conf"            "https://$NODE_IP:8443"                        system:node:minikube          "$C/kubelet-client.pem"       "$C/kubelet-client.pem"       false
# host access via the pinned 127.0.0.1:8443 publish; `make minikube` extracts this file
kubeconfig /var/lib/minikube/host.kubeconfig "https://127.0.0.1:8443"                  kubernetes-admin              "$TMP/admin.crt"              "$TMP/admin.key"              true

rm -f "$C"/*.srl "$C"/etcd/*.srl
echo "PKI + kubeconfigs generated:"
find "$C" "$K" -name '*.crt' -o -name '*.conf' | sort
