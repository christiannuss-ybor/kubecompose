# YP6M-3096 — GPU device path on the AKS flex node (Plan B: host driver + standalone device-plugin)

Node: `ybor-playground-dev-westus2` flex node, label `p6m.dev/node-type=gpu-shared` (currently `ip-172-31-94-237-g7e-2xlarge`; IP cycles — target by label). OS Ubuntu 24.04.4, kernel **6.17.0-1019-aws**, containerd 2.1.8, kubelet 1.33.8. kubectl context `ybor-playground-dev-westus2.p6m`.

## Why this shape (context for the ticket)
The flex node runs kubelet + containerd inside a **systemd-nspawn machine `kube1`**. Two hard constraints fell out of that:

1. **`kube1` doesn't expose `/sys/module`** (verified via a privileged sysfs probe: only block/bus/class/dev/devices/kernel are mounted). So the gpu-operator's **containerized driver** can't load the kernel module — `nvidia-driver-daemonset` dies at container creation (`mkdir /sys/module: read-only file system`, binding the Blackwell GSP firmware path). → **driver must be host-installed on the EC2 host OS** (nspawn shares the host kernel).
2. **The `nvidia-operator` namespace is in the istio-ambient mesh** and ztunnel on the flex node is `0/1` (broken), so the operator's operand pods there fail (sandbox create, then CrashLoop on captured egress). The ambient label is applied by the o11n/platform layer and **healed back by ArgoCD** whenever removed — not overridable from `ybor-playground/.platform`. → **don't rely on the gpu-operator operands on this node.**

**Decision (Plan B):** on the flex node, do the GPU device path ourselves, entirely outside the mesh —
- driver on the **EC2 host**,
- container-toolkit + nvidia runtime configured **inside `kube1`**,
- a **standalone NVIDIA device-plugin** DaemonSet in **`kube-system`** (confirmed `dataplane-mode=none`, non-meshed) to advertise `nvidia.com/gpu`.

gpu-operator stays configured for this node (PRs #148 flexnode tolerations, #149 `driver.enabled=false`) but its operands sit mesh-blocked and are **not** on the critical path; if/when Christian's network rework fixes ztunnel, they can take back over and this standalone plugin can be retired.

Cleared already: flexnode toleration (`ybor-playground/.platform#148`, merged); `driver.enabled=false` (`#149`, merging). ztunnel/ambient = Christian's network rework (open; we route around it via Plan B).

---

## PART A — NVIDIA driver on the EC2 HOST  (you run, as root on the host)
Access: flex-node-system debug sidecar (`k9s` → attach the flex-node pod on the gpu node → `ubuntu@host` → `sudo -i`), or SSM. Installs into the **host** OS, NOT kube1.

```bash
sudo -i
set -euxo pipefail

# A1. Sanity: GPU on the PCI bus + running kernel
lspci -nn | grep -i nvidia
uname -r                                    # expect 6.17.0-1019-aws

# A2. Headers for the RUNNING kernel + build toolchain (DKMS needs these)
apt-get update
apt-get install -y "linux-headers-$(uname -r)" build-essential dkms

# A3. NVIDIA CUDA network repo (Ubuntu 24.04 / x86_64)
cd /tmp
curl -fsSLO https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt-get update

# A4. Install the OPEN 580 driver (Blackwell REQUIRES open kernel modules) + userspace
apt-get install -y nvidia-driver-580-open nvidia-utils-580
#   fallbacks: apt-get install -y nvidia-open   | or:  cuda-drivers-580
#   ⚠ RISK #1: DKMS building the open module against kernel 6.17-aws is the real unknown.
#   On failure grab /var/lib/dkms/nvidia/*/build/make.log; try the .run installer
#   (--kernel-module-type=open) or a newer driver branch.

# A5. Load modules + verify ON THE HOST  ← PART A SUCCESS GATE
modprobe nvidia && modprobe nvidia_uvm && modprobe nvidia_modeset
nvidia-smi                                  # MUST list the Blackwell GPU
cat /proc/driver/nvidia/version
ls -l /dev/nvidia*
```
**Outcome (2026-07-23): ✅ SUCCESS.** DKMS built + loaded the **open** module against kernel 6.17.0-1019-aws (Risk #1 cleared). `nvidia-smi` on host: **NVIDIA RTX PRO 6000 Blackwell**, 97887 MiB (~96 GB) VRAM, 600W, driver **580.173.02**, CUDA 13.0. `/proc/driver/nvidia/version`: "NVIDIA UNIX Open Kernel Module x86_64 580.173.02". Device nodes present: /dev/nvidia0, /dev/nvidiactl, /dev/nvidia-uvm, /dev/nvidia-uvm-tools, /dev/nvidia-caps/{cap1,cap2}. No /dev/nvidia-modeset (headless card — Part B bind is guarded, skips it). **→ pin the kube1 userspace to 580.173.02 (see B5).**

---

## PART B — expose the GPU into `kube1` + configure the nvidia runtime  (you run, on the host)
kube1 shares the host kernel (module loaded in A5); it needs the device nodes, cgroup permission, the userspace libs, and the containerd nvidia runtime. Same append-after-`start` `kube1.nspawn` mechanism the `/etc/ssh` bind proved.

```bash
# B0. PREFERRED codified knob first — does aks-flex-node do device passthrough itself?
grep -iE "device|nvidia|AdditionalHostDevices" /etc/aks-flex-node/config.json \
  || echo "no device knob -> nspawn edit below (codify in cloud-init later)"

NSPAWN=/etc/systemd/nspawn/kube1.nspawn

# B1. Bind the NVIDIA device nodes into kube1
for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools /dev/nvidia-modeset; do
  [ -e "$dev" ] && ! grep -qxF "Bind=$dev" "$NSPAWN" && sed -i "/^\[Files\]/a Bind=$dev" "$NSPAWN"
done
[ -d /dev/nvidia-caps ] && ! grep -qxF "Bind=/dev/nvidia-caps" "$NSPAWN" \
  && sed -i "/^\[Files\]/a Bind=/dev/nvidia-caps" "$NSPAWN"

# B2. Grant the machine cgroup access to the devices
mkdir -p /etc/systemd/system/systemd-nspawn@kube1.service.d
cat > /etc/systemd/system/systemd-nspawn@kube1.service.d/10-nvidia.conf <<'EOF'
[Service]
DeviceAllow=/dev/nvidiactl rwm
DeviceAllow=/dev/nvidia0 rwm
DeviceAllow=/dev/nvidia-uvm rwm
DeviceAllow=/dev/nvidia-uvm-tools rwm
DeviceAllow=/dev/nvidia-modeset rwm
EOF

# B2.5. CRITICAL: /dev/nvidia0 + /dev/nvidiactl are DYNAMIC nodes — the driver removes them
#   when the GPU is idle, so they must be persistent BEFORE the nspawn bind or nspawn skips
#   them (observed 2026-07-23: only nvidia-uvm/uvm-tools/caps bound; nvidia0/nvidiactl missing
#   because they'd been cleaned up). Enable persistence so they stay present.
apt-get install -y nvidia-persistenced 2>/dev/null || true
systemctl enable --now nvidia-persistenced 2>/dev/null || nvidia-persistenced --verbose &
nvidia-smi -pm 1 || true
ls -l /dev/nvidia0 /dev/nvidiactl        # must exist + persist now

# B3. Reload + restart the machine (brief kube1/kubelet bounce — harmless)
systemctl daemon-reload && systemctl restart systemd-nspawn@kube1

# B3b. verify ALL five nodes are now inside the RUNNING machine (host dir view is misleading)
LEADER=$(machinectl show kube1 -p Leader --value)
nsenter -t "$LEADER" -m -p -- ls -l /dev | grep -i nvidia   # expect nvidia0, nvidiactl, uvm, uvm-tools, caps

# B3c. INSURANCE: nvidia0/nvidiactl are DYNAMIC nodes; on a partial/timed-out restart the bind
#   can transiently not land (observed: one restart showed only uvm/uvm-tools/caps). Add a
#   tmpfiles rule INSIDE kube1 so its systemd-tmpfiles-setup-dev recreates them at every boot.
#   (cgroup access is already granted by the DeviceAllow drop-in from B2.)
cat > /var/lib/machines/kube1/etc/tmpfiles.d/nvidia-devices.conf <<'EOF'
c /dev/nvidia0   0666 - - - 195:0
c /dev/nvidiactl 0666 - - - 195:255
EOF
# NOTE: `systemctl restart systemd-nspawn@kube1` is SLOW (drains+rejoins the node) and has
# timed out once -- give it generous time; don't assume a hang.

# B4. Confirm device nodes visible inside kube1
ls -l /var/lib/machines/kube1/dev/nvidia* 2>&1

# B5. Userspace + container-toolkit INSIDE kube1. ⚠ The userspace libs MUST match the host
#     kernel module EXACTLY = 580.173.02, or NVML errors "Driver/library version mismatch".
#     Use the SAME NVIDIA CUDA repo the host used (A3) so the version resolves identically.
#     ⚠ RISK #2: this is 3096's flagged "toolkit inside the nspawn" unknown.
machinectl shell kube1 /bin/bash -c '
  set -eux
  export DEBIAN_FRONTEND=noninteractive
  apt-get update && apt-get install -y curl gpg ca-certificates
  # same CUDA repo as the host (A3) -> same 580.173.02 userspace
  cd /tmp
  curl -fsSLO https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
  dpkg -i cuda-keyring_1.1-1_all.deb
  apt-get update
  # pin to the loaded module version; nvidia-utils gives nvidia-smi+libnvidia-ml, the compute pkg gives libcuda
  apt-get install -y nvidia-utils-580=580.173.02-0ubuntu1 libnvidia-compute-580=580.173.02-0ubuntu1 \
    || apt-get install -y nvidia-utils-580 libnvidia-compute-580   # fallback if that exact deb rev differs
  # container-toolkit
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https#g" \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update && apt-get install -y nvidia-container-toolkit
  nvidia-smi   # MUST print the same 580.173.02 + the GPU (no version-mismatch)
'

# B6. Configure the nvidia runtime in kube1s containerd + restart it (bounces node pods briefly)
#     This registers the `nvidia` runtime handler the runtimeClass points at.
machinectl shell kube1 /bin/bash -c '
  set -eux
  nvidia-ctk runtime configure --runtime=containerd --set-as-default=false
  systemctl restart containerd
'
```
**Outcome:** _fill in: config.json knob? / nvidia-smi inside kube1 / nvidia-ctk configure result / containerd restart_

---

## PART C — standalone NVIDIA device-plugin (Plan B) in the non-meshed `kube-system` ns
Apply from your workstation AFTER Parts A+B validate (it needs the host driver + nvidia runtime). Deploying earlier just CrashLoops until the driver is present.

```bash
CTX=ybor-playground-dev-westus2.p6m
kubectl --context $CTX apply -f - <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-flexnode
  namespace: kube-system            # dataplane-mode=none -> NOT meshed, dodges ztunnel
  labels: {app: nvidia-device-plugin-flexnode, managed-by: yp6m-3096}
spec:
  selector: {matchLabels: {app: nvidia-device-plugin-flexnode}}
  template:
    metadata: {labels: {app: nvidia-device-plugin-flexnode}}
    spec:
      priorityClassName: system-node-critical
      runtimeClassName: nvidia       # nvidia runtime (B6) injects driver libs + /dev into the plugin
      nodeSelector: {p6m.dev/node-type: gpu-shared}
      tolerations:
      - {key: flexnode, operator: Exists, effect: NoSchedule}
      - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
      containers:
      - name: nvidia-device-plugin-ctr
        image: nvcr.io/nvidia/k8s-device-plugin:v0.17.1
        env:
        - {name: NVIDIA_VISIBLE_DEVICES, value: "all"}
        - {name: NVIDIA_DRIVER_CAPABILITIES, value: "all"}
        - {name: FAIL_ON_INIT_ERROR, value: "true"}
        securityContext: {privileged: true}
        volumeMounts:
        - {name: device-plugin, mountPath: /var/lib/kubelet/device-plugins}
      volumes:
      - name: device-plugin
        hostPath: {path: /var/lib/kubelet/device-plugins}
EOF
kubectl --context $CTX -n kube-system rollout status ds/nvidia-device-plugin-flexnode --timeout=120s
kubectl --context $CTX -n kube-system logs ds/nvidia-device-plugin-flexnode | tail -20
```
Manifest used adds `runtimeClassName: nvidia` + `NVIDIA_VISIBLE_DEVICES=all` + `NVIDIA_DRIVER_CAPABILITIES=all` + `privileged` (the nvidia runtime from B6 injects the driver/GPU into the plugin). **This is now codified in `charts/flex-node-system` (always rendered, self-targeting GPU nodes — no enable flag), not a hand-applied file** — the chart renders the device-plugin DaemonSet with `hostNetwork: true` (skips the CNI chain, so it's not gated by the istio-cni window below), scoped to GPU flex nodes via `nodeSelector: p6m.dev/node-type=gpu-shared`. It also creates its own chart-owned `RuntimeClass/nvidia-flex` (handler `nvidia`) — a flex-scoped object distinct from the cluster's existing `nvidia` RuntimeClass, so pods here don't inherit any scheduling constraints the shared one carries and there's no Helm ownership clash (`gpu.runtimeClass.{create,name,handler}`). The inline heredoc above is kept only as the record of what was applied by hand during the spike.
**Outcome (2026-07-23): ✅ `nvidia.com/gpu` CAP=1, ALLOC=1** on the g7e; device-plugin `1/1 Running`; logs: "Registered device plugin for 'nvidia.com/gpu' with Kubelet". **3096 core criterion (node advertises nvidia.com/gpu) MET.**

### ⚠ BLOCKER hit during Part C — istio-cni in the flex-node CNI chain
Pods on the g7e wedge in `ContainerCreating`: the terraform-rendered `/var/lib/machines/kube1/etc/cni/net.d/10-flexnet.conflist` chains **3 plugins: `bridge`, `portmap`, `istio-cni`**. `istio-cni` fails every sandbox with `stat /var/run/istio-cni/istio-cni-kubeconfig: no such file or directory` — it crashes during client setup BEFORE applying its own `exclude_namespaces:[kube-system]`, so even excluded pods fail. The kubeconfig is written by `istio-cni-node`, which is **NOT hostNetwork** → it needs the CNI chain → **deadlock** (can't start to write the file the CNI needs). The B6 `containerd restart` cleared the runtime state and triggered it.
- **Unblock (host, per-node, reversible):** remove the `istio-cni` plugin from `10-flexnet.conflist` (python filter; backup `.pre-istio.bak`). containerd auto-reloads the CNI dir; the pod's next sandbox retry succeeds via bridge+portmap. **BUT a reconciler (istio `install-cni`) re-injects `istio-cni` within seconds** — so it's a *window*, not durable. The device-plugin (and test pod) each caught the window on a sandbox retry right after the removal.
- **DURABLE fix (kubecompose, Christian):** drop `istio-cni` from the terraform CNI template for the flex node (it's baked into `cni_conf`), and stop the `install-cni` reconciler — i.e. the flex node should not chain istio-cni at all (it can't run ambient mesh; ztunnel is 0/1). This is the network-rework he's already doing.

---

## PART D — verify (from your workstation)  ← FINAL SUCCESS GATE
```bash
CTX=ybor-playground-dev-westus2.p6m
kubectl --context $CTX get nodes -l p6m.dev/node-type=gpu-shared \
  -o custom-columns='NODE:.metadata.name,GPU:.status.capacity.nvidia\.com/gpu'   # expect GPU=1

kubectl --context $CTX apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: cuda-smoke, namespace: default}   # default = non-meshed
spec:
  restartPolicy: Never
  runtimeClassName: nvidia
  nodeSelector: {p6m.dev/node-type: gpu-shared}
  tolerations:
  - {key: flexnode, operator: Exists, effect: NoSchedule}
  - {key: nvidia.com/gpu, operator: Exists, effect: NoSchedule}
  containers:
  - name: smi
    image: nvcr.io/nvidia/cuda:12.6.2-base-ubuntu24.04
    command: ["nvidia-smi"]
    resources: {limits: {nvidia.com/gpu: 1}}
EOF
kubectl --context $CTX -n default logs cuda-smoke      # nvidia-smi from inside a pod
```
**Outcome (2026-07-23): ✅ SUCCEEDED.** `cuda-smoke` (default ns, `runtimeClassName: nvidia`, `nvidia.com/gpu:1`) ran `nvidia-smi` and saw the RTX PRO 6000 Blackwell (580.173.02, 96 GB) from inside the pod. Full path proven: host driver → nspawn passthrough → kube1 userspace+nvidia runtime → device-plugin → GPU-limited pod. **NOTE:** to schedule it we had to reopen the CNI window (remove istio-cni) so the pod caught its sandbox retry — the istio-cni reconciler re-adds it, so pod scheduling on the g7e is currently WINDOW-based until the durable CNI fix lands (see Part C blocker).

---

## To codify afterward (kubecompose + .platform, so it survives node cycles)
- **cloud-init.sh.tftpl**: Part A (driver install) + **enable `nvidia-persistenced`** (so /dev/nvidia0 + nvidiactl persist for the bind — confirmed necessary) + Part B (nspawn device binds — afn has NO device knob, so `kube1.nspawn` `Bind=` is the mechanism; userspace pinned to the driver version; `nvidia-ctk runtime configure`).
- **Part C device-plugin**: fold into `charts/flex-node-system` (3096's intended home) instead of a hand-applied DaemonSet.
- Prefer a **pre-baked GPU AMI** over build-at-boot if DKMS-on-6.17 proves slow/fragile (3096 open question).
- ztunnel/ambient: Christian's network rework — once fixed, the gpu-operator operands (already configured via #148/#149) can resume and the standalone plugin retires.
- Service-quota check for the g7e family (3096 open item).
