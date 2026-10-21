#!/usr/bin/env bash
# Works out HOW the cluster Prometheus should reach the host exporters, then
# wires the scrape configs in. Two modes exist because WSL2 NAT + Windows
# Firewall make pod->host scraping unreliable:
#
#   pod  - cluster Prometheus scrapes windows_exporter / node_exporter /
#          gpu_exporter / promtail directly
#   edge - those scrapes move to a WSL-side Prometheus
#          (scripts/edge-prometheus.sh) that remote_writes into the cluster
#
# Reachability is probed, not assumed: from inside a cluster pod, and from WSL.
# The outcome is recorded in $OBS_STATE/host-targets.env and rendered into
# $OBS_STATE/host-targets.yaml (pod view), $OBS_STATE/edge-targets.yaml (WSL
# view) and $OBS_STATE/kps-host-values.yaml, which the kube-prometheus-stack
# upgrade consumes.
set -euo pipefail
source "$(dirname "$0")/env.sh"

ENVF="$OBS_STATE/host-targets.env"
LOG="$OBS_STATE/host-targets.log"
PROBE_IMAGE="${PROBE_IMAGE:-busybox:1.36}"
PROBE_POD=obs-probe

WSL_IP="$(wsl_host_ip)"
GW_IP="$(windows_gateway_ip)"
: > "$LOG"

# Probes run inside command substitutions, so their commentary must not go to
# stdout or it would end up inside the captured target value.
note() { echo "$*" >> "$LOG"; echo "$*" >&2; }

# ---- cluster must exist ----------------------------------------------------
if ! kube get namespace "$MON_NS" >/dev/null 2>&1; then
  echo "error: no cluster/context '$KUBE_CONTEXT' (run scripts/cluster.sh first)" >&2
  exit 1
fi
if [ -z "$WSL_IP" ]; then echo "error: could not determine this distro's eth0 IPv4" >&2; exit 1; fi
note "wsl eth0: $WSL_IP   windows gateway: $GW_IP"

# ---- probes ---------------------------------------------------------------
pod_ready=false
probe_pod() {
  docker pull "$PROBE_IMAGE" > /dev/null 2>&1 || note "warn: could not pull $PROBE_IMAGE"
  "$OBS_BIN/kind" load docker-image "$PROBE_IMAGE" --name "$CLUSTER_NAME" > /dev/null 2>&1 \
    || note "warn: could not load $PROBE_IMAGE into the cluster"
  kube delete pod "$PROBE_POD" --ignore-not-found > /dev/null 2>&1
  kube run "$PROBE_POD" --image="$PROBE_IMAGE" --restart=Never --command -- sh -c "sleep 600" \
    > /dev/null || return 1
  kube wait --for=condition=Ready "pod/$PROBE_POD" --timeout=90s > /dev/null 2>&1 || return 1
  pod_ready=true
}

# pod_ok <host:port> - can a cluster pod GET /metrics from it?
pod_ok() {
  [ "$pod_ready" = true ] || return 1
  kube exec "$PROBE_POD" -- sh -c "wget -q -T 5 -O /dev/null http://$1/metrics" > /dev/null 2>&1
}

# wsl_ok <url> - can this distro reach it?
wsl_ok() { curl -fsS --max-time 5 "$1" > /dev/null 2>&1; }

# first_ok <label> <probe-fn> <candidate...> - echo the first reachable one.
first_ok() {
  local label="$1" probe="$2" cand
  shift 2
  for cand in "$@"; do
    if "$probe" "$cand"; then
      note "ok: $label reachable at $cand"
      printf '%s' "$cand"
      return 0
    fi
    note "no: $label not reachable at $cand"
  done
  printf 'disabled'
  return 0
}

probe_pod || note "warn: probe pod never became Ready; pod-side scraping will be skipped"

WINDOWS_TARGET="$(first_ok windows-host pod_ok "$GW_IP:$WINDOWS_EXPORTER_PORT" "host.docker.internal:$WINDOWS_EXPORTER_PORT")"
WSL_TARGET="$(first_ok wsl-host pod_ok "$WSL_IP:$NODE_EXPORTER_PORT")"
GPU_TARGET="$(first_ok wsl-gpu pod_ok "$WSL_IP:$GPU_EXPORTER_PORT")"
PROMTAIL_TARGET="$(first_ok wsl-promtail pod_ok "$WSL_IP:$PROMTAIL_HOST_PORT")"

# The edge fallback only helps if WSL itself can reach the exporters.
EDGE_WIN="$(first_ok windows-host-from-wsl wsl_ok "http://$GW_IP:$WINDOWS_EXPORTER_PORT/metrics")"
EDGE_WSL="$(first_ok wsl-host-from-wsl wsl_ok "http://localhost:$NODE_EXPORTER_PORT/metrics")"
EDGE_GPU="$(first_ok wsl-gpu-from-wsl wsl_ok "http://localhost:$GPU_EXPORTER_PORT/metrics")"
EDGE_PROMTAIL="$(first_ok wsl-promtail-from-wsl wsl_ok "http://localhost:$PROMTAIL_HOST_PORT/metrics")"

# The pod-side scrape of the edge Prometheus only exists in edge mode; in pod
# mode it stays "disabled" so the rendered job block is dropped.
EDGE_TARGET=disabled
EDGE_REQUIRED=0
for t in "$WINDOWS_TARGET" "$WSL_TARGET" "$GPU_TARGET" "$PROMTAIL_TARGET"; do
  [ "$t" = disabled ] && EDGE_REQUIRED=1
done
# Nothing is reachable from either side means the exporters are not running at
# all - scripts/exporters.sh is the fix, not the mode.
if [ "$EDGE_REQUIRED" = 1 ] && [ "$EDGE_WIN" = disabled ] && [ "$EDGE_WSL" = disabled ]; then
  echo "error: no host exporter reachable from WSL or from pods; run scripts/exporters.sh" >&2
  exit 1
fi
note "mode: $([ "$EDGE_REQUIRED" = 1 ] && echo edge || echo pod)"

# ---- where do host-side pushes go? ---------------------------------------
# Loki and Prometheus are exposed on the Windows host ports by Docker Desktop's
# extraPortMappings, so WSL reaches them through localhost or the gateway.
# Loki/Prometheus answers on the Windows host ports, so probe localhost first
# (Docker Desktop's port exposure) and fall back to the gateway address.
LOKI_URL="$(first_ok loki-ready-from-wsl wsl_ok \
  "http://localhost:$LOKI_HOST_PORT/ready" "http://$GW_IP:$LOKI_HOST_PORT/ready")"
LOKI_URL="$(printf '%s' "$LOKI_URL" | sed -e 's|^http://\(.*\)/ready$|http://\1/loki/api/v1/push|')"
[ "$LOKI_URL" = disabled ] && LOKI_URL="http://localhost:$LOKI_HOST_PORT/loki/api/v1/push"

REMOTE_WRITE_URL="$(first_ok prometheus-readable-from-wsl wsl_ok \
  "http://localhost:$PROM_HOST_PORT/api/v1/query?query=up" "http://$GW_IP:$PROM_HOST_PORT/api/v1/query?query=up")"
[ "$REMOTE_WRITE_URL" = disabled ] && REMOTE_WRITE_URL="http://localhost:$PROM_HOST_PORT/api/v1/query?query=up"
REMOTE_WRITE_URL="${REMOTE_WRITE_URL%/api/v1/query*}/api/v1/write"
note "loki push: $LOKI_URL"
note "remote_write: $REMOTE_WRITE_URL"

# ---- record + render -------------------------------------------------------
cat > "$ENVF" <<EOF
# Written by scripts/host-targets.sh ($(date -Is)); regenerate by re-running it.
# WSL reassigns eth0 IPs on restart, so re-run this after a reboot.
export MODE="$([ "$EDGE_REQUIRED" = 1 ] && echo edge || echo pod)"
export WINDOWS_TARGET="$WINDOWS_TARGET"
export WSL_TARGET="$WSL_TARGET"
export GPU_TARGET="$GPU_TARGET"
export PROMTAIL_TARGET="$PROMTAIL_TARGET"
export EDGE_TARGET="$EDGE_TARGET"
export EDGE_REQUIRED="$EDGE_REQUIRED"
export EDGE_WIN_TARGET="$EDGE_WIN"
export EDGE_WSL_TARGET="$EDGE_WSL"
export EDGE_GPU_TARGET="$EDGE_GPU"
export EDGE_PROMTAIL_TARGET="$EDGE_PROMTAIL"
export LOKI_URL="$LOKI_URL"
export REMOTE_WRITE_URL="$REMOTE_WRITE_URL"
EOF
note "recorded: $ENVF"

# The edge Prometheus is what makes pod-side scraping possible in edge mode, so
# it has to be running before its port can be probed. It also stops itself when
# EDGE_REQUIRED=0, which keeps a mode change from leaving a stray scraper behind.
"$OBS_ROOT/scripts/edge-prometheus.sh" > "$OBS_STATE/edge-prom.log" 2>&1 \
  || note "warn: edge Prometheus not started (see $OBS_STATE/edge-prom.log)"
if [ "$EDGE_REQUIRED" = 1 ]; then
  EDGE_TARGET="$(first_ok edge-prometheus pod_ok "$WSL_IP:$EDGE_PROM_PORT" "$GW_IP:$EDGE_PROM_PORT")"
  sed -i "s|^export EDGE_TARGET=.*|export EDGE_TARGET=\"$EDGE_TARGET\"|" "$ENVF"
fi

# Replace the placeholders, then drop whole job blocks whose target is
# "disabled" so Prometheus never shows a target that cannot exist.
render_targets() { # render_targets <dest> <win> <wsl> <gpu> <promtail> <edge>
  local dest="$1"
  sed -e "s|@WINDOWS_TARGET@|$2|g" -e "s|@WSL_TARGET@|$3|g" \
      -e "s|@GPU_TARGET@|$4|g" -e "s|@PROMTAIL_TARGET@|$5|g" \
      -e "s|@EDGE_TARGET@|$6|g" "$OBS_ROOT/monitoring/scrape/host-targets.tpl.yaml" \
    | awk '
        /^- job_name:/ { flush(); block = $0 "\n"; next }
        { block = block $0 "\n" }
        END { flush() }
        function flush() { if (block != "" && block !~ /disabled/) printf "%s", block }
      ' > "$dest"
  note "rendered: $dest"
}

# The rendered list is a set of YAML list items at column 0, so it can be
# nested under any parent key by prefixing spaces to every line.
indent() { # indent <spaces> <file>
  sed "s/^/$(printf '%*s' "$1" '')/" "$2"
}

# Pod view: only the targets a cluster pod proved reachable.
render_targets "$OBS_STATE/host-targets.yaml" \
  "$WINDOWS_TARGET" "$WSL_TARGET" "$GPU_TARGET" "$PROMTAIL_TARGET" "$EDGE_TARGET"
# WSL view: what the edge Prometheus scrapes - localhost for this distro's own
# exporters, the gateway IP for windows_exporter.
render_targets "$OBS_STATE/edge-targets.yaml" \
  "$EDGE_WIN" "$EDGE_WSL" "$EDGE_GPU" "$EDGE_PROMTAIL" disabled

# kube-prometheus-stack merge: base values plus the host scrape list.
{
  echo "prometheus:"
  echo "  prometheusSpec:"
  echo "    additionalScrapeConfigs:"
  indent 6 "$OBS_STATE/host-targets.yaml"
} > "$OBS_STATE/kps-host-values.yaml"
note "rendered: $OBS_STATE/kps-host-values.yaml"

# Host logs now ship to the Loki endpoint WSL actually reached.
"$OBS_ROOT/scripts/exporters.sh" promtail > "$OBS_STATE/promtail-relaunch.log" 2>&1 \
  || note "warn: host promtail not restarted (see $OBS_STATE/promtail-relaunch.log)"

helm upgrade --install obs "$KPS_CHART" \
  --version "$KPS_CHART_VERSION" --namespace "$MON_NS" \
  -f "$OBS_ROOT/monitoring/values/kube-prometheus-stack.yaml" \
  -f "$OBS_STATE/kps-host-values.yaml" \
  --set "grafana.adminPassword=$GRAFANA_ADMIN_PASSWORD" \
  > "$OBS_STATE/kps-host-upgrade.log" 2>&1 \
  || { echo "error: helm upgrade failed, see $OBS_STATE/kps-host-upgrade.log" >&2; exit 1; }
note "helm: kube-prometheus-stack upgraded with the host scrape configs"

kube rollout status "deploy/obs-kube-prometheus-stack-operator" --timeout=120s > /dev/null 2>&1 || true
kube rollout status "statefulset/obs-kube-prometheus-stack-prometheus" --timeout=180s > /dev/null 2>&1 || true
kube delete pod "$PROBE_POD" --ignore-not-found > /dev/null 2>&1

echo "--- host wiring ---"
grep -v '^#' "$ENVF"
echo "probes: $LOG"
echo "next: scripts/verify.sh"
