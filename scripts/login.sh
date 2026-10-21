#!/usr/bin/env bash
# Prints the login details for the deployed stack: the URL to open in a Windows
# browser, the Grafana user and password, and where that password came from.
# The password is read from the live cluster secret when the cluster is up, so
# the output matches what Grafana actually accepts.
set -euo pipefail
source "$(dirname "$0")/env.sh"

password="$GRAFANA_ADMIN_PASSWORD"
origin="${OBS_SECRETS#$OBS_ROOT/} (or the default in scripts/env.sh)"

live="$(kube get secret obs-grafana -n "$MON_NS" -o jsonpath='{.data.admin-password}' 2> /dev/null | base64 -d)"
if [ -n "$live" ]; then
  password="$live"
  origin="secret obs-grafana in namespace $MON_NS"
fi

echo "--- Grafana ---"
printf 'url         http://localhost:%s\n' "$GRAFANA_HOST_PORT"
printf 'user        %s\n' "$GRAFANA_ADMIN_USER"
printf 'password    %s\n' "$password"
printf 'stored in   %s\n' "$origin"
printf 'change      GRAFANA_ADMIN_PASSWORD=<new> ./scripts/deploy.sh\n'

echo
echo "--- other endpoints (no auth) ---"
printf 'prometheus    http://localhost:%s\n' "$PROM_HOST_PORT"
printf 'alertmanager  http://localhost:%s\n' "$ALERT_HOST_PORT"
printf 'loki          http://localhost:%s\n' "$LOKI_HOST_PORT"
printf 'grafana api   curl -u "%s:%s" http://localhost:%s/api/dashboards/uid/obs-cluster\n' \
  "$GRAFANA_ADMIN_USER" "$password" "$GRAFANA_HOST_PORT"
