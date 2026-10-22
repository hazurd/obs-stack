#!/usr/bin/env bash
# Prints the login details for the deployed stack: the URL to open in a Windows
# browser, the Grafana user and password, where that password came from, and the
# direct links to the dashboards.
# Grafana keeps the admin password in its own database, so the cluster secret and
# .state/secrets.env can both be stale if the password was changed in the web UI.
# Every candidate is therefore probed against the API and the one that works is
# reported.
set -euo pipefail
source "$(dirname "$0")/env.sh"

probe() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    -u "$GRAFANA_ADMIN_USER:$1" \
    "http://localhost:$GRAFANA_HOST_PORT/api/dashboards/uid/obs-cluster" 2> /dev/null || echo 000
}

# Candidates, in the order they are tried: the value env.sh resolved (an explicit
# GRAFANA_ADMIN_PASSWORD, then .state/secrets.env, then the default), then the
# live cluster secret.
passwords=("$GRAFANA_ADMIN_PASSWORD")
origins=("${OBS_SECRETS#$OBS_ROOT/} (scripts/env.sh)")
live="$(kube get secret obs-grafana -n "$MON_NS" -o jsonpath='{.data.admin-password}' 2> /dev/null | base64 -d)"
if [ -n "$live" ] && [ "$live" != "$GRAFANA_ADMIN_PASSWORD" ]; then
  passwords+=("$live")
  origins+=("secret obs-grafana in namespace $MON_NS")
fi

password=""
origin=""
code="000"
for i in "${!passwords[@]}"; do
  code="$(probe "${passwords[$i]}")"
  if [ "$code" = 200 ]; then
    password="${passwords[$i]}"
    origin="${origins[$i]}"
    break
  fi
done

echo "--- Grafana ---"
printf 'url         http://localhost:%s\n' "$GRAFANA_HOST_PORT"
printf 'user        %s\n' "$GRAFANA_ADMIN_USER"
if [ -n "$password" ]; then
  printf 'password    %s\n' "$password"
  printf 'stored in   %s\n' "$origin"
  printf 'auth        ok (the password above is accepted)\n'
else
  printf 'password    %s  (NOT accepted by grafana)\n' "${passwords[0]}"
  printf 'tried       %s\n' "${origins[0]}"
  printf '            %s\n' "${origins[1]:-no other candidate}"
  printf 'grafana rejects both, so the password was changed in the web UI.\n'
  printf 'Record the UI password with:\n'
  printf '  GRAFANA_ADMIN_PASSWORD=%s ./scripts/deploy.sh\n' "'<the password you set in the UI>'"
  printf 'or make grafana accept the recorded one again with:\n'
  printf '  kube exec deploy/obs-grafana -n %s -c grafana -- grafana cli admin reset-admin-password %s\n' "$MON_NS" "'<new>'"
fi
printf 'change      GRAFANA_ADMIN_PASSWORD=<new> ./scripts/deploy.sh\n'

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
