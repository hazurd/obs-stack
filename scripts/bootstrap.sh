#!/usr/bin/env bash
# Download pinned tool + exporter binaries into the repo-local .bin/ and make
# sure the helm chart repos are present. Idempotent.
set -euo pipefail
source "$(dirname "$0")/env.sh"

dl() { # dl <url> <dest>
  if [ -s "$2" ]; then echo "ok: $(basename "$2") already present"; return 0; fi
  echo "downloading: $1"
  curl -fsSL "$1" -o "$2"
}

fetch_kubectl() {
  if [ -x "$OBS_BIN/kubectl" ]; then return 0; fi
  dl "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl" "$OBS_BIN/kubectl.tmp"
  chmod +x "$OBS_BIN/kubectl.tmp"
  mv "$OBS_BIN/kubectl.tmp" "$OBS_BIN/kubectl"
}

fetch_kind() {
  if [ -x "$OBS_BIN/kind" ]; then return 0; fi
  dl "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-amd64" "$OBS_BIN/kind.tmp"
  chmod +x "$OBS_BIN/kind.tmp"
  mv "$OBS_BIN/kind.tmp" "$OBS_BIN/kind"
}

fetch_node_exporter() {
  if [ -x "$OBS_BIN/node_exporter" ]; then return 0; fi
  dl "https://github.com/prometheus/node_exporter/releases/download/v$NODE_EXPORTER_VERSION/node_exporter-$NODE_EXPORTER_VERSION.linux-amd64.tar.gz" "$OBS_STATE/node_exporter.tar.gz"
  tar -xzf "$OBS_STATE/node_exporter.tar.gz" -C "$OBS_BIN"
  mv "$OBS_BIN"/node_exporter-"$NODE_EXPORTER_VERSION".linux-amd64/node_exporter "$OBS_BIN/node_exporter"
  rm -rf "$OBS_BIN"/node_exporter-"$NODE_EXPORTER_VERSION".linux-amd64 "$OBS_STATE/node_exporter.tar.gz"
}

fetch_windows_exporter() {
  dl "https://github.com/prometheus-community/windows_exporter/releases/download/v$WINDOWS_EXPORTER_VERSION/windows_exporter-$WINDOWS_EXPORTER_VERSION-amd64.exe" "$OBS_BIN/windows_exporter.exe"
}

fetch_edge_prometheus() {
  if [ -x "$OBS_BIN/prometheus" ]; then return 0; fi
  dl "https://github.com/prometheus/prometheus/releases/download/v$PROM_EDGE_VERSION/prometheus-$PROM_EDGE_VERSION.linux-amd64.tar.gz" "$OBS_STATE/prometheus.tar.gz"
  tar -xzf "$OBS_STATE/prometheus.tar.gz" -C "$OBS_BIN" --wildcards '*/prometheus'
  mv "$OBS_BIN"/prometheus-"$PROM_EDGE_VERSION".linux-amd64/prometheus "$OBS_BIN/prometheus"
  rm -rf "$OBS_BIN"/prometheus-"$PROM_EDGE_VERSION".linux-amd64 "$OBS_STATE/prometheus.tar.gz"
}

fetch_promtail() {
  # Promtail no longer publishes standalone binaries, so the WSL-side host log
  # shipper is lifted out of the chart's image (same version the chart ships).
  if [ -x "$OBS_BIN/promtail" ]; then return 0; fi
  docker pull "grafana/promtail:$PROMTAIL_VERSION" >/dev/null || {
    echo "warn: could not pull grafana/promtail:$PROMTAIL_VERSION; host logs will not be shipped"
    return 0
  }
  local cid
  cid="$(docker create "grafana/promtail:$PROMTAIL_VERSION")"
  docker cp "$cid":/usr/bin/promtail "$OBS_BIN/promtail.tmp"
  docker rm "$cid" >/dev/null
  chmod +x "$OBS_BIN/promtail.tmp"
  mv "$OBS_BIN/promtail.tmp" "$OBS_BIN/promtail"
  echo "ok: promtail from grafana/promtail:$PROMTAIL_VERSION"
}

helm_repos() {
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
  helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
  helm repo update >/dev/null
  echo "ok: helm repos ready"
  helm search repo prometheus-community/kube-prometheus-stack --versions | head -2
  helm search repo grafana/loki --versions | head -2
}

check_env() {
  command -v docker >/dev/null || { echo "missing: docker"; exit 1; }
  command -v helm >/dev/null || { echo "missing: helm"; exit 1; }
  command -v curl >/dev/null || { echo "missing: curl"; exit 1; }
  command -v powershell.exe >/dev/null || echo "warn: powershell.exe not found (Windows exporter unavailable)"
  docker info >/dev/null 2>&1 || { echo "docker daemon not reachable"; exit 1; }
  echo "ok: docker daemon reachable ($(docker version --format '{{.Server.Version}}'))"
  if [ -x /usr/lib/wsl/lib/nvidia-smi ]; then
    echo "ok: gpu $(/usr/lib/wsl/lib/nvidia-smi --query-gpu=name,memory.total --format=csv,noheader)"
  else
    echo "warn: nvidia-smi not found; gpu exporter will not run"
  fi
}

fetch_kubectl
fetch_kind
fetch_node_exporter
fetch_windows_exporter
fetch_edge_prometheus
helm_repos
check_env

echo "--- versions ---"
"$OBS_BIN/kind" --version
"$OBS_BIN/kubectl" version --client 2>/dev/null | head -1
"$OBS_BIN/node_exporter" --version | head -1

echo "bootstrap done. binaries in $OBS_BIN"
