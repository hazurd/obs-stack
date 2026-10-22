#!/usr/bin/env python3
"""Replay every panel query in the obs dashboards and report the empty ones.

A dashboard can be provisioned and still be useless: the query is wrong, the
metric name does not exist in the exporter that serves it, or the datasource
variable points nowhere. This reads the dashboard JSON out of Grafana's API and
runs each target against Prometheus and Loki on their host ports, so a wiring
break shows up as a failing panel rather than as a wall of "No data".

Emptiness that is a fact about the system rather than a bug is listed in
EXPECTED_EMPTY with the reason, and is reported as a warning instead of a
failure. Anything else - a rejected query, an absent metric - fails the run.

  scripts/check-dashboards.py [uid ...]

Environment (scripts/env.sh provides all of these):
  GRAFANA_URL PROM_URL LOKI_URL GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD
"""

import base64
import json
import os
import sys
import time
import urllib.parse
import urllib.request

GRAFANA = os.environ.get("GRAFANA_URL", "http://localhost:3000")
PROM = os.environ.get("PROM_URL", "http://localhost:9090")
LOKI = os.environ.get("LOKI_URL", "http://localhost:31000")
USER = os.environ.get("GRAFANA_ADMIN_USER", "admin")

OBS_ROOT = os.environ.get("OBS_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OBS_STATE = os.environ.get("OBS_STATE") or os.path.join(OBS_ROOT, ".state")


def recorded_password():
    """The password scripts/deploy.sh saved in .state/secrets.env, so the script
    can run standalone instead of requiring scripts/env.sh to be sourced first."""
    password = os.environ.get("GRAFANA_ADMIN_PASSWORD")
    if password:
        return password
    try:
        with open(os.path.join(OBS_STATE, "secrets.env"), encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("GRAFANA_ADMIN_PASSWORD="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


PASSWORD = recorded_password()

# Grafana's own default window is now-6h; an hour is long enough to catch a
# slow scrape interval without pulling the whole retention range.
WINDOW = int(os.environ.get("OBS_PANEL_WINDOW", "3600"))
STEP = int(os.environ.get("OBS_PANEL_STEP", "60"))

UIDS = ("obs-windows-host", "obs-wsl-host", "obs-gpu", "obs-cluster")

# Panels that legitimately return nothing. Keyed by (dashboard uid, title).
EXPECTED_EMPTY = {
    ("obs-wsl-host", "Failed units"):
        "no systemd unit is in the failed state - the stat panel above shows 0",
    ("obs-wsl-host", "journald errors"):
        "filters log text; empty means no journald line contained 'error'",
    ("obs-wsl-host", "distro log files"):
        "filters log text; empty means no tailed distro log contained 'error'",
    ("obs-gpu", "Exporter log (journald)"):
        "filters log text; empty means the GPU exporter logged nothing recently",
    ("obs-gpu", "Memory held per process"):
        "nvidia-smi reports used_memory [N/A] for Windows-side processes under WSL",
    ("obs-cluster", "Containers not ready"):
        "every container is ready - the stat panel above shows 0",
    ("obs-cluster", "Monitoring pod logs"):
        "filters log text; empty means no monitoring pod line contained 'error'",
    ("obs-cluster", "Cluster pod logs"):
        "filters log text; empty means no cluster pod line contained 'error'",
}


def request(url, body=None, headers=None):
    """Fetch JSON. Prometheus wants GET or form-encoded params, not a JSON body."""
    data = urllib.parse.urlencode(body).encode() if body is not None else None
    hdr = {"Content-Type": "application/x-www-form-urlencoded"}
    hdr.update(headers or {})
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=hdr),
                                    timeout=25) as resp:
            return json.loads(resp.read())
    except Exception as exc:  # urllib raises HTTPError and URLError
        detail = getattr(exc, "read", None)
        if callable(detail):
            try:
                body_txt = json.loads(detail().decode()).get("message") or ""
            except Exception:
                body_txt = ""
            if body_txt:
                exc = f"{exc} - {body_txt}"
        return {"__error__": str(exc)}


def auth_header():
    token = base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
    return {"Authorization": f"Basic {token}"}


def dashboard(uid):
    """Grafana's dashboard API answers {"meta": ..., "dashboard": ...}."""
    doc = request(f"{GRAFANA}/api/dashboards/uid/{uid}", headers=auth_header())
    if "__error__" in doc:
        return None, doc["__error__"]
    if "dashboard" not in doc:
        return None, "grafana has no dashboard with this uid (scripts/deploy.sh)"
    return doc["dashboard"], None


def panels(dash):
    """Yield every query panel, including the ones nested inside a row."""
    for panel in dash.get("panels", []):
        if panel.get("type") == "row":
            for nested in panel.get("panels", []):
                yield nested
        elif panel.get("targets"):
            yield panel


def kind_of(panel):
    name = (panel.get("datasource") or {}).get("name") or ""
    return "loki" if "LOKI" in name.upper() else "prometheus"


def run_query(kind, expr, instant):
    now = int(time.time())
    if kind == "loki":
        out = request(
            f"{LOKI}/loki/api/v1/query_range",
            {
                "query": expr,
                "start": (now - WINDOW) * 10 ** 9,
                "end": now * 10 ** 9,
                "limit": 100,
            },
        )
        if "__error__" in out:
            return None, out["__error__"]
        streams = out.get("data", {}).get("result") or []
        return len(streams), None

    endpoint = "query" if instant else "query_range"
    params = {"query": expr, "time": now}
    if not instant:
        params.update({"start": now - WINDOW, "end": now, "step": STEP})
    out = request(f"{PROM}/api/v1/{endpoint}", params)
    if "__error__" in out:
        return None, out["__error__"]
    series = out.get("data", {}).get("result") or []
    points = sum(len(s.get("values") or s.get("value") or []) for s in series)
    return points, None


def main(argv):
    uids = argv or UIDS
    total = filled = expected = broken = 0

    for uid in uids:
        dash, err = dashboard(uid)
        if dash is None:
            print(f"fail: {uid}: cannot read dashboard from grafana: {err}")
            broken += 1
            continue

        for panel in panels(dash):
            kind = kind_of(panel)
            for target in panel["targets"]:
                expr = target.get("expr")
                if not expr:
                    continue
                total += 1
                count, err = run_query(kind, expr, bool(target.get("instant")))
                title = f"{uid} / {panel.get('title')} [{kind}] {target.get('refId', '')}".strip()

                if err:
                    print(f"fail: {title}: {err}\n        {expr[:120]}")
                    broken += 1
                elif count == 0:
                    reason = EXPECTED_EMPTY.get((uid, panel.get("title")))
                    if reason:
                        print(f"warn: {title}: empty - {reason}")
                        expected += 1
                    else:
                        print(f"fail: {title}: NO DATA\n        {expr[:120]}")
                        broken += 1
                else:
                    filled += 1

    summary = f"{filled}/{total} panel queries return data ({expected} empty as expected)"
    print(f"{summary}{' - ' + str(broken) + ' broken' if broken else ''}")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
