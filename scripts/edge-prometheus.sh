#!/usr/bin/env bash
# The fallback scraper: a Prometheus that runs in this WSL distro, scrapes the
# host exporters over localhost / the Windows gateway, and remote_writes the
# result into the in-cluster Prometheus that Grafana reads.
#
# scripts/host-targets.sh decides whether it is needed (EDGE_REQUIRED=1 in
# $OBS_STATE/host-targets.env) and records the WSL-side target list plus the
# remote_write endpoint. When it is not needed this script stops the unit, so
# re-running after a mode change leaves nothing behind.
set -euo pipefail
source "$(dirname "$0")/env.sh"

ENVF="$OBS_STATE/host-targets.env"
CFG="$OBS_STATE/edge-prometheus.yaml"
TARGETS="$OBS_STATE/edge-targets.yaml"

if [ ! -f "$ENVF" ]; then
  echo "error: $ENVF missing (run scripts/host-targets.sh first)" >&2
  exit 1
fi
# shellcheck disable=SC2046,SC1091
source "$ENVF"

if [ "${EDGE_REQUIRED:-0}" != 1 ]; then
  sudo systemctl disable --now "${EDGE_UNIT}.service" >/dev/null 2>&1 || true
  rm -f "$CFG"
  echo "ok: edge Prometheus not needed (pods reach the host exporters directly)"
  exit 0
fi

[ -x "$OBS_BIN/prometheus" ] || { echo "error: $OBS_BIN/prometheus missing (scripts/bootstrap.sh)" >&2; exit 1; }
[ -f "$TARGETS" ] || { echo "error: $TARGETS missing (run scripts/host-targets.sh first)" >&2; exit 1; }
: "${REMOTE_WRITE_URL:?REMOTE_WRITE_URL must be recorded by scripts/host-targets.sh}"

# The target list is a set of YAML list items at column 0; nesting it under
# scrape_configs: is a matter of prefixing two spaces.
{
  sed -e "s|@REMOTE_WRITE_URL@|$REMOTE_WRITE_URL|g" "$OBS_ROOT/monitoring/scrape/edge-prom.tpl.yaml"
  sed 's/^/  /' "$TARGETS"
} > "$CFG"
echo "ok: rendered $CFG"

# --dry-run parses the config and exits without starting a server.
"$OBS_BIN/prometheus" --config.file "$CFG" --dry-run > "$OBS_STATE/edge-prom-dry-run.log" 2>&1 \
  || { echo "error: edge config rejected, see $OBS_STATE/edge-prom-dry-run.log" >&2; exit 1; }

sudo tee "/etc/systemd/system/${EDGE_UNIT}.service" \
  < <(sed -e "s|@OBS_BIN@|$OBS_BIN|g" -e "s|@OBS_STATE@|$OBS_STATE|g" \
        -e "s|@EDGE_PROM_PORT@|$EDGE_PROM_PORT|g" \
        "$OBS_ROOT/exporters/wsl/edge-prometheus.service") > /dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now "${EDGE_UNIT}.service"
echo "ok: ${EDGE_UNIT}.service enabled on :$EDGE_PROM_PORT, remote_write -> $REMOTE_WRITE_URL"

sleep 2
systemctl is-active "${EDGE_UNIT}.service" >/dev/null && echo "ok: unit active" || echo "warn: unit not active (journalctl -u $EDGE_UNIT)"
curl -fsS --max-time 5 "http://localhost:$EDGE_PROM_PORT/metrics" > /dev/null \
  && echo "ok: edge metrics endpoint reachable" || echo "warn: edge metrics endpoint unreachable"
