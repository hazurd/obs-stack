#!/usr/bin/env python3
"""Appends journald entries to a JSON-lines file that promtail can tail.

WSL2 ships journald but no syslog daemon, so the distro's service logs only
exist in journald. Promtail has no journald input driver, therefore this unit
follows journald and writes one compact JSON object per entry:

  {"ts": <RFC3339Nano>, "msg": ..., "unit": ..., "service": ..., "priority": ..., "host": ...}

`ts` is a UTC RFC3339Nano string because promtail 3.5.1's timestamp stage only
understands Go reference layouts (named formats like "unixms" are rejected), so
promtail-host.yaml pairs it with layout 2006-01-02T15:04:05.999999999Z07:00.

Restarting with --since keeps replay bounded, and scripts/exporters.sh installs
a logrotate config so the file never grows without limit.

Environment:
  OBS_STATE       directory to write journald.log into (required)
  JOURNAL_SINCE   replay window on restart      (default "today")
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timezone

STATE = os.environ["OBS_STATE"]
OUT = os.path.join(STATE, "journald.log")
SINCE = os.environ.get("JOURNAL_SINCE", "today")
PRIORITY = {
    "7": "debug",
    "6": "info",
    "5": "notice",
    "4": "warning",
    "3": "error",
    "2": "crit",
    "1": "alert",
}


def compact(entry):
    try:
        ts = datetime.fromtimestamp(int(entry["__REALTIME_TIMESTAMP"]) / 1_000_000, timezone.utc)
    except (KeyError, TypeError, ValueError):
        ts = datetime.now(timezone.utc)
    return {
        "ts": ts.isoformat(),
        "msg": entry.get("MESSAGE", ""),
        "unit": entry.get("_SYSTEMD_UNIT") or entry.get("SYSLOG_IDENTIFIER") or "kernel",
        "service": entry.get("_COMM", ""),
        "priority": PRIORITY.get(entry.get("PRIORITY", "6"), "info"),
        "host": entry.get("_HOSTNAME", "wsl"),
    }


def main():
    # Keep journald itself small so a restart never replays gigabytes.
    subprocess.run(["journalctl", "--vacuum-size=100M"], check=False)
    proc = subprocess.Popen(
        ["journalctl", "--follow", "--output=json", "--since", SINCE],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    with open(OUT, "a", buffering=1) as fh:
        try:
            for raw in proc.stdout:
                try:
                    entry = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                fh.write(json.dumps(compact(entry)) + "\n")
        except KeyboardInterrupt:
            pass
        finally:
            proc.terminate()


if __name__ == "__main__":
    main()
