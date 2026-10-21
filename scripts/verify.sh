#!/usr/bin/env bash
# End-to-end check of the whole stack: cluster, in-cluster services, host
# exporters, the scrape wiring, dashboards, alert rules and log shipping.
# Exits non-zero when something is broken; warnings do not fail the run.
set -euo pipefail
source "$(dirname "$0")/env.sh"

FAIL=0
ok()   { echo "ok:   $*"; }
warn() { echo "warn: $*"; }
bad()  { echo "fail: $*"; FAIL=$((FAIL + 1)); }

http() { curl -fsS --max-time 8 -o /dev/null "$1" 2> "$OBS_STATE/verify-last-error"; }

# --- cluster ---------------------------------------------------------------
if kind get clusters 2> /dev/null | grep -qx "$CLUSTER_NAME"; then
  ok "kind cluster '$CLUSTER_NAME' exists"
else
  bad "kind cluster '$CLUSTER_NAME' missing (run scripts/cluster.sh)"
fi
if kube get nodes --no-headers 2> /dev/null | grep -q Ready; then
  ok "nodes Ready: $(kube get nodes --no-headers 2> /dev/null | wc -l)"
else
  bad "no Ready nodes (kubectl --context $KUBE_CONTEXT get nodes)"
fi

# --- in-cluster services ---------------------------------------------------
for release in obs obs-loki obs-promtail; do
  helm list -n "$MON_NS" --kube-context "$KUBE_CONTEXT" 2> /dev/null | grep -q "^${release}\b" \
    && ok "helm release '$release' deployed" || bad "helm release '$release' missing (run scripts/deploy.sh)"
done
not_ready=$(kube get pods -n "$MON_NS" --no-headers 2> /dev/null | grep -vc '^.*\(Running\|Completed\)' || true)
[ "$not_ready" = 0 ] && ok "all pods in $MON_NS running" || bad "$not_ready pod(s) in $MON_NS not running"

http "http://localhost:$GRAFANA_HOST_PORT/api/health" && ok "grafana  http://localhost:$GRAFANA_HOST_PORT" || bad "grafana unreachable on :$GRAFANA_HOST_PORT"
http "http://localhost:$PROM_HOST_PORT/-/healthy"     && ok "prometheus http://localhost:$PROM_HOST_PORT" || bad "prometheus unreachable on :$PROM_HOST_PORT"
http "http://localhost:$ALERT_HOST_PORT/-/healthy"    && ok "alertmanager http://localhost:$ALERT_HOST_PORT" || bad "alertmanager unreachable on :$ALERT_HOST_PORT"
http "http://localhost:$LOKI_HOST_PORT/ready"         && ok "loki http://localhost:$LOKI_HOST_PORT" || bad "loki unreachable on :$LOKI_HOST_PORT"

# --- host exporters --------------------------------------------------------
for unit in "$NODE_UNIT" "$GPU_UNIT" "$JOURNAL_UNIT" "$PROMTAIL_UNIT"; do
  systemctl is-active "$unit.service" > /dev/null 2>&1 \
    && ok "unit $unit active" || bad "unit $unit not active (journalctl -u $unit)"
done
http "http://localhost:$NODE_EXPORTER_PORT/metrics" && ok "wsl node_exporter :$NODE_EXPORTER_PORT" || bad "wsl node_exporter unreachable"
http "http://localhost:$GPU_EXPORTER_PORT/metrics"  && ok "wsl gpu_exporter :$GPU_EXPORTER_PORT"   || bad "wsl gpu_exporter unreachable"
http "http://localhost:$PROMTAIL_HOST_PORT/metrics" && ok "wsl promtail :$PROMTAIL_HOST_PORT"      || bad "wsl promtail unreachable"

GW_IP="$(windows_gateway_ip)"
http "http://$GW_IP:$WINDOWS_EXPORTER_PORT/metrics" \
  && ok "windows_exporter at $GW_IP:$WINDOWS_EXPORTER_PORT" \
  || bad "windows_exporter unreachable at $GW_IP:$WINDOWS_EXPORTER_PORT (firewall rule? scripts/exporters.sh windows)"

MODE="$(grep -E '^export MODE=' "$OBS_STATE/host-targets.env" 2> /dev/null | cut -d'"' -f2)"
if [ "$MODE" = edge ]; then
  systemctl is-active "$EDGE_UNIT.service" > /dev/null 2>&1 \
    && ok "edge Prometheus unit active (:$EDGE_PROM_PORT)" || bad "edge Prometheus unit not active"
  http "http://localhost:$EDGE_PROM_PORT/metrics" && ok "edge Prometheus :$EDGE_PROM_PORT" || bad "edge Prometheus unreachable"
fi

# --- what Prometheus actually scrapes --------------------------------------
TARGETS_JSON="$OBS_STATE/verify-targets.json"
if curl -fsS --max-time 15 "http://localhost:$PROM_HOST_PORT/api/v1/targets?state=any" > "$TARGETS_JSON"; then
  targets_report="$(python3 - "$TARGETS_JSON" <<'PY'
import json, sys

try:
    data = json.load(open(sys.argv[1]))
except Exception as exc:
    print(f"fail: cannot parse targets: {exc}")
    sys.exit(0)

targets = data.get("data", {}).get("activeTargets", [])
if not targets:
    print("fail: Prometheus has no targets at all (scripts/deploy.sh + prometheus operator)")
    sys.exit(0)

jobs = {}
for t in targets:
    job = t.get("labels", {}).get("job", "?")
    # "health" is the field both Prometheus v2 and v3 report; the older
    # "lastScrapeSucceeded" boolean is kept as a fallback for v2.0 targets.
    up = t.get("health") == "up" or bool(t.get("lastScrapeSucceeded"))
    jobs.setdefault(job, [0, 0])
    jobs[job][0] += up
    jobs[job][1] += 1

for job, (ups, total) in sorted(jobs.items()):
    print(f"{'ok  ' if ups == total else 'fail'}  {job:<34} {ups}/{total} up")

expected = {"windows-host", "wsl-host", "wsl-gpu", "wsl-promtail"}
missing = sorted(expected - set(jobs))
if missing:
    print(f"fail: host jobs absent: {', '.join(missing)} (scripts/host-targets.sh)")
PY
)"
  if [ -z "$targets_report" ]; then
    bad "could not parse Prometheus targets from $TARGETS_JSON"
  else
    printf '%s\n' "$targets_report"
    fails="$(printf '%s\n' "$targets_report" | grep -c '^fail')" || fails=0
    FAIL=$((FAIL + fails))
  fi
else
  bad "could not read Prometheus targets"
fi

# --- dashboards, rules, logs -----------------------------------------------
# Checked by uid rather than by search text, so the check is exact: the chart's
# own dashboards have unrelated titles and would skew a text search.
dash=0
for uid in obs-windows-host obs-wsl-host obs-gpu obs-cluster; do
  curl -fsS --max-time 8 -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
    "http://localhost:$GRAFANA_HOST_PORT/api/dashboards/uid/$uid" > /dev/null 2>&1 \
    && dash=$((dash + 1)) || warn "grafana dashboard '$uid' not provisioned (sidecar logs: kubectl -n $MON_NS logs deploy/obs-grafana -c grafana-sc-dashboard)"
done
[ "$dash" -ge 4 ] && ok "grafana dashboards present: $dash/4" || bad "only $dash/4 obs dashboards in grafana (scripts/deploy.sh)"

rules=$(curl -fsS --max-time 8 "http://localhost:$PROM_HOST_PORT/api/v1/rules" 2> /dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for g in d.get("data",{}).get("groups",[]) if g["name"].startswith("obs-")))' 2> /dev/null || echo 0)
[ "$rules" -ge 5 ] && ok "host alert rule groups loaded: $rules" || bad "obs-* alert groups missing ($rules)"

labels=$(curl -fsS --max-time 8 "http://localhost:$LOKI_HOST_PORT/loki/api/v1/labels" 2> /dev/null \
         | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("data",[])))' 2> /dev/null || echo 0)
[ "$labels" -gt 0 ] && ok "loki labels: $labels" || warn "loki has no labels yet (log shipping may still be catching up)"

# --- from the Windows side -------------------------------------------------
if command -v powershell.exe > /dev/null 2>&1; then
  code=$(win -Command "try { (Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost:$GRAFANA_HOST_PORT/api/health').StatusCode } catch { 'err' }" 2> /dev/null | tr -d '\r')
  [ "$code" = 200 ] && ok "windows can reach grafana at localhost:$GRAFANA_HOST_PORT" || bad "windows cannot reach localhost:$GRAFANA_HOST_PORT ($code)"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "$FAIL check(s) failed - see the lines above marked 'fail'"
  exit 1
fi
echo "everything checks out."
"$OBS_ROOT/scripts/login.sh"
