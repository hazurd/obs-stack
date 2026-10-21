#!/usr/bin/env bash
# Create the kind cluster "obs" on the Docker Desktop engine, or reuse it if it
# already exists. Writes a standalone kubeconfig in .kube/ so the existing
# ~/.kube/config is left untouched.
set -euo pipefail
source "$(dirname "$0")/env.sh"

[ -x "$OBS_BIN/kind" ] || { echo "error: $OBS_BIN/kind missing (run scripts/bootstrap.sh)" >&2; exit 1; }
docker info > /dev/null 2>&1 || { echo "error: docker daemon not reachable - start Docker Desktop" >&2; exit 1; }

# Raise the inotify instance limit before anything that watches files starts.
# The drop-in under /etc/sysctl.d survives a WSL reboot (systemd-applied).
sysctl_content="# Written by obs-stack (scripts/cluster.sh). See scripts/env.sh for why.
fs.inotify.max_user_instances=$INOTIFY_MAX_USER_INSTANCES"
if printf '%s\n' "$sysctl_content" | sudo tee "$INOTIFY_SYSCTL_FILE" > /dev/null \
   && sudo sysctl -p "$INOTIFY_SYSCTL_FILE" > /dev/null; then
  echo "ok: fs.inotify.max_user_instances=$(sysctl -n fs.inotify.max_user_instances)"
else
  echo "warn: could not write $INOTIFY_SYSCTL_FILE (needs sudo); promtail may fail with 'too many open files'" >&2
fi

if "$OBS_BIN/kind" get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "ok: cluster '$CLUSTER_NAME' already exists; reusing it"
else
  echo "creating kind cluster '$CLUSTER_NAME' with image $KIND_IMAGE"
  "$OBS_BIN/kind" create cluster \
    --name "$CLUSTER_NAME" \
    --image "$KIND_IMAGE" \
    --config "$OBS_ROOT/cluster/kind-cluster.yaml" \
    --kubeconfig "$OBS_KUBE_DIR/$CLUSTER_NAME.yaml"
fi

# A kubeconfig that predates this repo (or was deleted) is regenerated from the
# cluster rather than repaired by hand.
if ! kube get namespaces > /dev/null 2>&1; then
  echo "ok: regenerating $OBS_KUBE_DIR/$CLUSTER_NAME.yaml"
  "$OBS_BIN/kind" get kubeconfig --name "$CLUSTER_NAME" > "$OBS_KUBE_DIR/$CLUSTER_NAME.yaml"
fi

kube wait --for=condition=Ready nodes --all --timeout=180s > /dev/null
echo "--- cluster ---"
kube get nodes -o wide
echo "context: $KUBE_CONTEXT   kubeconfig: $KUBECONFIG"

# kind's extraPortMappings publish the NodePorts on the Docker host, which under
# Docker Desktop is also the Windows host - so Windows can use these URLs.
echo "--- host ports ---"
printf 'grafana       http://localhost:%s   (NodePort %s)\n' "$GRAFANA_HOST_PORT" "$GRAFANA_NODE_PORT"
printf 'prometheus    http://localhost:%s   (NodePort %s)\n' "$PROM_HOST_PORT" "$PROM_NODE_PORT"
printf 'alertmanager  http://localhost:%s   (NodePort %s)\n' "$ALERT_HOST_PORT" "$ALERT_NODE_PORT"
printf 'loki          http://localhost:%s   (NodePort %s)\n' "$LOKI_HOST_PORT" "$LOKI_NODE_PORT"
echo "next: scripts/exporters.sh"
