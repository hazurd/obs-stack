#!/usr/bin/env bash
# Render, install and start the exporters that run outside the cluster:
#   * Windows: windows_exporter.exe (started through powershell.exe)
#   * WSL:     node_exporter, gpu_exporter, journald follower, promtail,
#             and optionally the edge Prometheus fallback
# Everything is installed as systemd units so the exporters survive a reboot.
#
# Usage:
#   scripts/exporters.sh            # everything (all)
#   scripts/exporters.sh units      # WSL systemd units only
#   scripts/exporters.sh promtail   # re-render + restart WSL promtail only
#   scripts/exporters.sh windows    # Windows exporter only
# Idempotent: re-running after a WSL restart just re-renders and re-starts.
set -euo pipefail
source "$(dirname "$0")/env.sh"

# host-targets.sh records the Loki endpoint it proved reachable; when it has not
# run yet we assume the default host port mapping.
if [ -f "$OBS_STATE/host-targets.env" ]; then
  # shellcheck disable=SC2046,SC1091
  source "$OBS_STATE/host-targets.env"
fi
LOKI_URL="${LOKI_URL:-http://localhost:${LOKI_HOST_PORT}/loki/api/v1/push}"

UNITS="$OBS_STATE/units"
mkdir -p "$UNITS"

# Substitute the @PLACEHOLDER@ tokens in a template. Paths use | as the sed
# delimiter because Windows install paths contain backslashes.
render() { # render <template> <dest>
  sed -e "s|@OBS_ROOT@|$OBS_ROOT|g" \
      -e "s|@OBS_BIN@|$OBS_BIN|g" \
      -e "s|@OBS_STATE@|$OBS_STATE|g" \
      -e "s|@PYTHON@|$PYTHON|g" \
      -e "s|@NVIDIA_SMI@|$NVIDIA_SMI|g" \
      -e "s|@NODE_EXPORTER_PORT@|$NODE_EXPORTER_PORT|g" \
      -e "s|@GPU_EXPORTER_PORT@|$GPU_EXPORTER_PORT|g" \
      -e "s|@PROMTAIL_HOST_PORT@|$PROMTAIL_HOST_PORT|g" \
      -e "s|@EDGE_PROM_PORT@|$EDGE_PROM_PORT|g" \
      -e "s|@JOURNAL_SINCE@|$JOURNAL_SINCE|g" \
      -e "s|@JOURNAL_UNIT@|$JOURNAL_UNIT|g" \
      -e "s|@LOKI_URL@|$LOKI_URL|g" \
      "$1" > "$2"
}

install_unit() { # install_unit <unit-name> <rendered-file>
  local name="$1" file="$2"
  sudo tee "/etc/systemd/system/${name}.service" < "$file" > /dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable --now "${name}.service"
  echo "ok: ${name}.service enabled"
}

unit_state() { # unit_state <unit-name>
  systemctl is-active "$1" 2>/dev/null || echo inactive
}

# A missing promtail binary is a bootstrap problem, not a broken config, so it
# warns instead of aborting the other units.
promtail_present() { [ -x "$OBS_BIN/promtail" ]; }

render_units() {
  render "$OBS_ROOT/exporters/wsl/node-exporter.service" "$UNITS/${NODE_UNIT}.service"
  render "$OBS_ROOT/exporters/wsl/journal-follow.service" "$UNITS/${JOURNAL_UNIT}.service"
  render "$OBS_ROOT/exporters/wsl/promtail-host.service" "$UNITS/${PROMTAIL_UNIT}.service"
  render "$OBS_ROOT/exporters/wsl/promtail-host.yaml" "$OBS_STATE/promtail-host.yaml"
  # promtail validates its own config; fail here rather than in a restart loop.
  if promtail_present; then
    "$OBS_BIN/promtail" -config.file "$OBS_STATE/promtail-host.yaml" -check-syntax
  else
    echo "warn: $OBS_BIN/promtail not present (run scripts/bootstrap.sh); ${PROMTAIL_UNIT}.service skipped"
  fi
}

start_units() {
  install_unit "$JOURNAL_UNIT" "$UNITS/${JOURNAL_UNIT}.service"
  install_unit "$NODE_UNIT" "$UNITS/${NODE_UNIT}.service"
  if promtail_present; then
    install_unit "$PROMTAIL_UNIT" "$UNITS/${PROMTAIL_UNIT}.service"
  fi

  # WSL hands the GPU to this distro only when it is attached; /usr/lib/wsl/lib
  # is empty on a distro without one, so the unit is optional rather than fatal.
  if [ -x "$NVIDIA_SMI" ]; then
    render "$OBS_ROOT/exporters/gpu/gpu-exporter.service" "$UNITS/${GPU_UNIT}.service"
    install_unit "$GPU_UNIT" "$UNITS/${GPU_UNIT}.service"
  else
    echo "warn: $NVIDIA_SMI not executable; skipping ${GPU_UNIT}.service (GPU panels stay empty)"
    sudo systemctl disable "${GPU_UNIT}.service" 2>/dev/null || true
  fi
}

start_promtail() {
  render_units
  promtail_present || return 0
  install_unit "$PROMTAIL_UNIT" "$UNITS/${PROMTAIL_UNIT}.service"
  sudo systemctl restart "${PROMTAIL_UNIT}.service"
  echo "ok: ${PROMTAIL_UNIT}.service restarted with Loki $LOKI_URL"
}

start_windows() {
  local ps1="$OBS_ROOT/exporters/windows/windows-exporter.ps1"
  win -File "$ps1" -Action start -Source "$OBS_BIN/windows_exporter.exe" \
      -Port "$WINDOWS_EXPORTER_PORT" -Collectors "$WINDOWS_EXPORTER_COLLECTORS"
  # Adding an inbound rule needs an elevated PowerShell; a plain WSL-initiated
  # call is refused with "Access is denied", which is not fatal - the README
  # tells the user to run the firewall action themselves once.
  win -File "$ps1" -Action firewall -Port "$WINDOWS_EXPORTER_PORT" 2>/dev/null \
    || echo "warn: firewall rule for :${WINDOWS_EXPORTER_PORT} not added (needs elevated PowerShell)"
  win -File "$ps1" -Action scrape -Port "$WINDOWS_EXPORTER_PORT"
}

listening() { # listening <port> <label>
  if ss -ltn "sport = :$1" 2>/dev/null | grep -q LISTEN; then
    echo "ok: $2 listening on :$1"
  else
    echo "warn: $2 not listening on :$1"
  fi
}

case "${1:-all}" in
  units)
    render_units
    start_units
    ;;
  promtail)
    start_promtail
    ;;
  windows)
    start_windows
    ;;
  all)
    render_units
    start_units
    start_windows
    ;;
  *)
    echo "unknown action: $1 (expected all|units|promtail|windows)" >&2
    exit 2
    ;;
esac

echo "--- WSL listener state ---"
listening "$NODE_EXPORTER_PORT" node_exporter
listening "$GPU_EXPORTER_PORT" gpu_exporter
listening "$PROMTAIL_HOST_PORT" promtail
for u in "$JOURNAL_UNIT" "$NODE_UNIT" "$GPU_UNIT" "$PROMTAIL_UNIT"; do
  echo "$u: $(unit_state "$u")"
done
