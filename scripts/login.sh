#!/usr/bin/env bash
# Prints the login details for the deployed stack: the URL to open in a Windows
# browser, the Grafana user and password, where that password came from, and the
# direct links to the dashboards.
# The password is read from the live cluster secret when the cluster is up, so
# the output matches what Grafana's secret holds. Grafana only applies that
# secret to a fresh database, so a password changed in the web UI is not
# reflected here; that case is probed below and reported.
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

# Does this password actually work? Grafana keeps the password in its database,
# so if it was changed in the web UI the value above is stale.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
  -u "$GRAFANA_ADMIN_USER:$password" \
  "http://localhost:$GRAFANA_HOST_PORT/api/dashboards/uid/obs-cluster" 2> /dev/null || echo 000)
if [ "$code" = 200 ]; then
  printf 'auth        ok (the password above is accepted)\n'
elif [ "$code" = 401 ]; then
  printf 'auth        FAILED: grafana rejects this password, so it was changed in\n'
  printf '            the web UI. Record the UI password with:\n'
  printf '              GRAFANA_ADMIN_PASSWORD=%s ./scripts/deploy.sh\n' "'<the password you set in the UI>'"
  printf '            or make grafana accept the recorded one again with:\n'
  printf '              kube exec deploy/obs-grafana -n %s -c grafana -- grafana cli admin reset-admin-password %s\n' "$MON_NS" "'<new>'"
else
  printf 'auth        could not be checked (http %s)\n' "$code"
fi

echo
echo "--- dashboards (open directly, or Dashboards -> Browse) ---"
for uid in obs-windows-host obs-wsl-host obs-gpu obs-cluster; do
  printf 'http://localhost:%s/d/%s\n' "$GRAFANA_HOST_PORT" "$uid"
done

echo
echo "--- other endpoints (no auth) ---"
printf 'prometheus    http://localhost:%s\n' "$PROM_HOST_PORT"
printf 'alertmanager  http://localhost:%s\n' "$ALERT_HOST_PORT"
printf 'loki          http://localhost:%s\n' "$LOKI_HOST_PORT"
