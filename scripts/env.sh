# Shared environment for every obs-stack script.
# Sourced by scripts/*.sh. Nothing here mutates the host.
# shellcheck shell=bash

OBS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OBS_ROOT
export OBS_BIN="$OBS_ROOT/.bin"
export OBS_STATE="$OBS_ROOT/.state"
export OBS_KUBE_DIR="$OBS_ROOT/.kube"

mkdir -p "$OBS_BIN" "$OBS_STATE" "$OBS_KUBE_DIR"

# --- pinned versions -------------------------------------------------------
export KIND_VERSION="${KIND_VERSION:-v0.33.0}"
# kind v0.33.0 defaults to this image; pinned by digest so a cluster recreate
# cannot silently change the node image.
export KIND_IMAGE="${KIND_IMAGE:-kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}"
export KUBECTL_VERSION="${KUBECTL_VERSION:-v1.37.0}"
export KPS_CHART_VERSION="${KPS_CHART_VERSION:-92.11.0}"
export LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-7.3.0}"
export PROMTAIL_CHART_VERSION="${PROMTAIL_CHART_VERSION:-6.17.1}"
export NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.12.1}"
export WINDOWS_EXPORTER_VERSION="${WINDOWS_EXPORTER_VERSION:-0.31.9}"
export PROMTAIL_VERSION="${PROMTAIL_VERSION:-3.5.1}"
export PROM_EDGE_VERSION="${PROM_EDGE_VERSION:-3.15.0}"

# Chart references (repos are added by scripts/bootstrap.sh).
export KPS_CHART="${KPS_CHART:-prometheus-community/kube-prometheus-stack}"
export LOKI_CHART="${LOKI_CHART:-grafana/loki}"
export PROMTAIL_CHART="${PROMTAIL_CHART:-grafana/promtail}"

# --- kernel limits ---------------------------------------------------------
# WSL2 has ONE kernel shared by this distro and Docker Desktop's engine distro,
# and fs.inotify.max_user_instances is charged per uid across it. kubelet,
# containerd, systemd and the kind nodes all run as root, so the stock 128
# instances run out and promtail aborts with "too many open files" while
# building its file target manager. Raised by scripts/cluster.sh.
export INOTIFY_SYSCTL_FILE="${INOTIFY_SYSCTL_FILE:-/etc/sysctl.d/99-obs-inotify.conf}"
export INOTIFY_MAX_USER_INSTANCES="${INOTIFY_MAX_USER_INSTANCES:-1024}"

# --- cluster / namespace ---------------------------------------------------
export CLUSTER_NAME="${CLUSTER_NAME:-obs}"
export MON_NS="${MON_NS:-monitoring}"
export KUBE_CONTEXT="kind-${CLUSTER_NAME}"

# kind writes its own kubeconfig; prepend it so the kind context wins while the
# pre-existing ~/.kube/config contexts stay usable.
export KUBECONFIG="$OBS_KUBE_DIR/${CLUSTER_NAME}.yaml:$HOME/.kube/config"
export PATH="$OBS_BIN:$PATH"

# --- in-cluster NodePorts <-> host ports (kind extraPortMappings) ----------
export GRAFANA_NODE_PORT="${GRAFANA_NODE_PORT:-30000}"
export GRAFANA_HOST_PORT="${GRAFANA_HOST_PORT:-3000}"
export PROM_NODE_PORT="${PROM_NODE_PORT:-30090}"
export PROM_HOST_PORT="${PROM_HOST_PORT:-9090}"
export ALERT_NODE_PORT="${ALERT_NODE_PORT:-30903}"
export ALERT_HOST_PORT="${ALERT_HOST_PORT:-9093}"
export LOKI_NODE_PORT="${LOKI_NODE_PORT:-31000}"
export LOKI_HOST_PORT="${LOKI_HOST_PORT:-31000}"

# --- fallback: WSL-side edge Prometheus (only used when pods cannot reach the
# host exporters; it remote_writes into the in-cluster Prometheus) ----------
export EDGE_PROM_PORT="${EDGE_PROM_PORT:-9190}"

export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"

# --- host exporters (run outside the cluster) ------------------------------
export NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9101}"
export GPU_EXPORTER_PORT="${GPU_EXPORTER_PORT:-9104}"
export WINDOWS_EXPORTER_PORT="${WINDOWS_EXPORTER_PORT:-9182}"
export WINDOWS_INSTALL_DIR="${WINDOWS_INSTALL_DIR:-C:\\obs-stack}"
export WINDOWS_INSTALL_WSL="${WINDOWS_INSTALL_WSL:-/mnt/c/obs-stack}"
# Collector set validated against windows_exporter 0.31.9: this build has no
# "diskio" or "perfmon" collector (disk I/O ships with logical_disk /
# physical_disk), and the gpu collector silently yields nothing under WSL, so
# GPU metrics come from exporters/gpu/gpu_exporter.py instead.
export WINDOWS_EXPORTER_COLLECTORS="${WINDOWS_EXPORTER_COLLECTORS:-cpu,cpu_info,memory,logical_disk,physical_disk,net,os,service,process,system,time,tcp,pagefile}"

# --- WSL log shipping ------------------------------------------------------
# promtail 3.5.1 has no usable journald input driver in the binaries grafana
# publishes (a journal scrape config parses but discovers no targets here), and
# WSL2 has no syslog daemon, so exporters/wsl/journal-follow.py converts
# journald into JSON lines that promtail tails.
export PROMTAIL_HOST_PORT="${PROMTAIL_HOST_PORT:-9105}"
export JOURNAL_SINCE="${JOURNAL_SINCE:-today}"
export PYTHON="${PYTHON:-python3}"
export NVIDIA_SMI="${NVIDIA_SMI:-/usr/lib/wsl/lib/nvidia-smi}"

# --- systemd units scripts/exporters.sh installs ---------------------------
export NODE_UNIT="${NODE_UNIT:-obs-node-exporter}"
export GPU_UNIT="${GPU_UNIT:-obs-gpu-exporter}"
export JOURNAL_UNIT="${JOURNAL_UNIT:-obs-journal-follow}"
export PROMTAIL_UNIT="${PROMTAIL_UNIT:-obs-promtail-host}"
export EDGE_UNIT="${EDGE_UNIT:-obs-edge-prometheus}"

# --- helpers ---------------------------------------------------------------
kube() { kubectl --context "$KUBE_CONTEXT" "$@"; }

wsl_host_ip() { ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1; }

windows_gateway_ip() { ip route 2>/dev/null | awk '/^default/{print $3}' | head -1; }

win() { powershell.exe -NoProfile -ExecutionPolicy Bypass "$@"; }
