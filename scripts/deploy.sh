#!/usr/bin/env bash
# Deploys the in-cluster monitoring stack into the "obs" kind cluster:
#   kube-prometheus-stack  Prometheus + Grafana + Alertmanager + kube exporters
#   loki                   log store (single binary, filesystem storage)
#   promtail               DaemonSet that ships pod logs into Loki
# then patches the NodePorts that cluster/kind-cluster.yaml maps to host ports,
# loads the Grafana dashboards and applies the host alert rules.
#
# Run scripts/host-targets.sh afterwards to wire the host exporters in.
set -euo pipefail
source "$(dirname "$0")/env.sh"

command -v helm > /dev/null 2>&1 || { echo "error: helm not installed" >&2; exit 1; }
kube get nodes > /dev/null 2>&1 || { echo "error: cluster '$CLUSTER_NAME' not reachable (run scripts/cluster.sh)" >&2; exit 1; }

# scripts/host-targets.sh nests the host scrape configs into this file; it is
# absent on a fresh deploy, which is fine - host metrics arrive later.
VALUES_HOST="$OBS_STATE/kps-host-values.yaml"
HELM_ARGS=(--namespace "$MON_NS" --create-namespace --kube-context "$KUBE_CONTEXT" --wait --timeout 15m)

deploy() { # deploy <release> <chart> <version> [extra helm args...]
  local release="$1" chart="$2" version="$3"
  shift 3
  helm upgrade --install "$release" "$chart" \
    --version "$version" "${HELM_ARGS[@]}" "$@"
}

echo "--- kube-prometheus-stack $KPS_CHART_VERSION ---"
deploy obs "$KPS_CHART" "$KPS_CHART_VERSION" \
  -f "$OBS_ROOT/monitoring/values/kube-prometheus-stack.yaml" \
  --set "grafana.adminPassword=$GRAFANA_ADMIN_PASSWORD" \
  $([ -f "$VALUES_HOST" ] && echo "-f $VALUES_HOST")

# Keep the password this run used, so scripts/verify.sh and the next deploy log
# in with the same credentials. 0600 and gitignored (.state/).
umask 077
printf 'GRAFANA_ADMIN_PASSWORD=%s\n' "$GRAFANA_ADMIN_PASSWORD" > "$OBS_SECRETS"
echo "ok: grafana login saved to ${OBS_SECRETS#$OBS_ROOT/}"

echo "--- loki $LOKI_CHART_VERSION ---"
deploy obs-loki "$LOKI_CHART" "$LOKI_CHART_VERSION" \
  -f "$OBS_ROOT/monitoring/values/loki.yaml"

echo "--- promtail $PROMTAIL_CHART_VERSION ---"
deploy obs-promtail "$PROMTAIL_CHART" "$PROMTAIL_CHART_VERSION" \
  -f "$OBS_ROOT/monitoring/values/promtail.yaml"

# kind's extraPortMappings publish NodePorts on the Docker host, which under
# Docker Desktop is also the Windows host. The charts do not set NodePorts, so
# the services are patched here.
patch_node_port() { # patch_node_port <svc> <service port> <nodePort>
  local svc="$1" port="$2" node_port="$3" idx
  idx=$(kube get svc "$svc" -n "$MON_NS" -o jsonpath='{range .spec.ports[*]}{.port}{"\n"}{end}' \
        | grep -n "^$port$" | head -1 | cut -d: -f1)
  [ -n "$idx" ] || { echo "error: $svc has no port $port" >&2; return 1; }
  idx=$((idx - 1))
  kube patch svc "$svc" -n "$MON_NS" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/$idx/nodePort\",\"value\":$node_port}]" > /dev/null
  echo "ok: $svc port $port -> NodePort $node_port"
}
patch_node_port obs-grafana                          80   "$GRAFANA_NODE_PORT"
patch_node_port obs-kube-prometheus-stack-prometheus 9090 "$PROM_NODE_PORT"
patch_node_port obs-kube-prometheus-stack-alertmanager 9093 "$ALERT_NODE_PORT"
patch_node_port obs-loki                             3100 "$LOKI_NODE_PORT"

# Dashboards travel as ConfigMaps labelled grafana_dashboard="1", which the
# kube-prometheus-stack sidecar turns into Grafana entries. `kubectl create
# configmap` cannot set labels, so the YAML is generated here.
python3 - "$OBS_ROOT/monitoring/dashboards" "$MON_NS" <<'PY' | kube apply -f - > /dev/null
import os, sys, textwrap

dash_dir, ns = sys.argv[1], sys.argv[2]
for f in sorted(os.listdir(dash_dir)):
    if not f.endswith(".json"):
        continue
    name = f[:-5]
    body = open(os.path.join(dash_dir, f)).read().rstrip("\n")
    # kubectl only splits documents on "---"; without it the stream parses as a
    # single ConfigMap and every dashboard but the last one is silently lost.
    print(f"---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n"
          f"  name: grafana-dash-{name}\n  namespace: {ns}\n"
          f'  labels:\n    grafana_dashboard: "1"\n'
          f"data:\n  {f}: |\n{textwrap.indent(body, '    ')}")
PY
echo "ok: dashboards applied"
applied=$(kube get configmap -n "$MON_NS" -l grafana_dashboard=1 --no-headers 2> /dev/null | grep -c '^grafana-dash-obs-')
[ "$applied" -ge 4 ] || { echo "error: only $applied obs dashboard ConfigMaps present in $MON_NS" >&2; exit 1; }
echo "ok: $applied obs dashboard ConfigMaps present"

kube apply -f "$OBS_ROOT/monitoring/rules/host-alerts.yaml" > /dev/null
echo "ok: host alert rules applied"

kube wait --for=condition=Available deployments --all -n "$MON_NS" --timeout=180s > /dev/null || true
echo "--- pods ---"
kube get pods -n "$MON_NS" -o wide

echo "--- login and host URLs ---"
"$OBS_ROOT/scripts/login.sh"
echo "next: scripts/exporters.sh && scripts/host-targets.sh"
