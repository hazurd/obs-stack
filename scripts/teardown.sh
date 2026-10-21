#!/usr/bin/env bash
# Takes the stack down: helm releases, the kind cluster, the Windows exporter and
# the WSL systemd units. Binaries in .bin/ survive unless OBS_PURGE=1 is set,
# because re-downloading them is the slow part of a rebuild.
set -euo pipefail
source "$(dirname "$0")/env.sh"

for release in obs-loki obs-promtail obs; do
  helm uninstall "$release" -n "$MON_NS" --kube-context "$KUBE_CONTEXT" > /dev/null 2>&1 \
    && echo "ok: uninstalled helm release $release" || echo "skip: $release not installed"
done

if kind get clusters 2> /dev/null | grep -qx "$CLUSTER_NAME"; then
  kind delete cluster --name "$CLUSTER_NAME" > /dev/null
  echo "ok: deleted kind cluster '$CLUSTER_NAME'"
fi

win -File "$OBS_ROOT/exporters/windows/windows-exporter.ps1" -Action stop > /dev/null 2>&1 \
  && echo "ok: windows_exporter stopped" || echo "skip: windows_exporter not running"

if [ "${OBS_KEEP_EXPORTERS:-0}" = 1 ]; then
  echo "ok: WSL units left installed (OBS_KEEP_EXPORTERS=1)"
else
  for unit in "$EDGE_UNIT" "$PROMTAIL_UNIT" "$JOURNAL_UNIT" "$GPU_UNIT" "$NODE_UNIT"; do
    systemctl is-active "$unit.service" > /dev/null 2>&1 && sudo systemctl disable --now "$unit.service" > /dev/null
    sudo rm -f "/etc/systemd/system/$unit.service"
  done
  sudo systemctl daemon-reload
  echo "ok: WSL systemd units removed"
fi

# Undo the inotify bump scripts/cluster.sh made, so the shared WSL2 kernel goes
# back to the distro default. The drop-in is ours, so deleting it is safe.
if [ -f "$INOTIFY_SYSCTL_FILE" ]; then
  sudo rm -f "$INOTIFY_SYSCTL_FILE"
  sudo sysctl -w fs.inotify.max_user_instances=128 > /dev/null 2>&1 || true
  echo "ok: removed $INOTIFY_SYSCTL_FILE (fs.inotify.max_user_instances=$(sysctl -n fs.inotify.max_user_instances))"
fi

rm -rf "$OBS_STATE"
rm -f "$OBS_KUBE_DIR/$CLUSTER_NAME.yaml"
echo "ok: cleared $OBS_STATE and $OBS_KUBE_DIR/$CLUSTER_NAME.yaml"

if [ "${OBS_PURGE:-0}" = 1 ]; then
  rm -rf "$OBS_BIN"
  echo "ok: removed $OBS_BIN"
else
  echo "ok: kept $OBS_BIN (OBS_PURGE=1 to remove it)"
fi

echo "note: $WINDOWS_INSTALL_DIR on Windows is left in place; delete it by hand if you want it gone."
