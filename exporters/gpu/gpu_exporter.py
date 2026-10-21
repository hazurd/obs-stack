#!/usr/bin/env python3
"""Exposes NVIDIA GPU metrics to Prometheus by shelling out to nvidia-smi.

Stdlib only: no vendor SDK, no DCGM. Under WSL2 nvidia-smi lives in
/usr/lib/wsl/lib/nvidia-smi and reports the Windows GPU, which is exactly
what we want to monitor.

Environment:
  NVIDIA_SMI          path to nvidia-smi          (default /usr/lib/wsl/lib/nvidia-smi)
  GPU_EXPORTER_PORT   listen port                 (default 9104)
"""

import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NVIDIA_SMI = os.environ.get("NVIDIA_SMI", "/usr/lib/wsl/lib/nvidia-smi")
PORT = int(os.environ.get("GPU_EXPORTER_PORT", "9104"))

# nvidia-smi's memory columns are MiB; the *_bytes metrics need real bytes.
MIB = 1024 * 1024

FIELDS = (
    "index,name,uuid,driver_version,memory.total,memory.used,memory.free,"
    "utilization.gpu,utilization.memory,temperature.gpu,power.draw"
)
HELP = {
    "gpu_info": "Static GPU metadata as labels; always 1.",
    "gpu_memory_total_bytes": "Total GPU memory in bytes.",
    "gpu_memory_used_bytes": "GPU memory currently used in bytes.",
    "gpu_memory_free_bytes": "GPU memory currently free in bytes.",
    "gpu_utilization_percent": "GPU utilization (0-100).",
    "gpu_memory_utilization_percent": "GPU memory utilization (0-100).",
    "gpu_temperature_celsius": "GPU temperature in Celsius.",
    "gpu_power_draw_watts": "GPU power draw in watts.",
    "gpu_compute_processes": "Number of compute processes on the GPU.",
    "gpu_compute_process_memory_mib": "Memory used by each compute process, in MiB.",
    "gpu_smi_query_errors_total": "nvidia-smi invocations that failed since startup.",
    "gpu_exporter_up": "1 when the exporter process is serving.",
}
TYPE = {
    # Prometheus's text format has no "info" type; gpu_info is metadata-only,
    # so it is declared untyped (declaring "info" makes the scrape fail with
    # "invalid metric type \"info\"").
    "gpu_info": "untyped",
    "gpu_memory_total_bytes": "gauge",
    "gpu_memory_used_bytes": "gauge",
    "gpu_memory_free_bytes": "gauge",
    "gpu_utilization_percent": "gauge",
    "gpu_memory_utilization_percent": "gauge",
    "gpu_temperature_celsius": "gauge",
    "gpu_power_draw_watts": "gauge",
    "gpu_compute_processes": "gauge",
    "gpu_compute_process_memory_mib": "gauge",
    "gpu_smi_query_errors_total": "counter",
    "gpu_exporter_up": "gauge",
}

errors = 0


def smi(args):
    """Run nvidia-smi with csv output, no headers, no unit suffixes."""
    out = subprocess.run(
        [NVIDIA_SMI, *args],
        capture_output=True,
        text=True,
        timeout=15,
        check=True,
    )
    rows = []
    for line in out.stdout.splitlines():
        line = line.strip()
        if not line or line.startswith("CUDA Error") or line.startswith("GPU"):
            continue
        rows.append([field.strip() for field in line.split(",")])
    return rows


def num(value):
    """nvidia-smi sometimes reports '[N/A]'."; treat it as unusable."""
    try:
        return float(value)
    except ValueError:
        return None


def render():
    global errors
    lines = []
    try:
        rows = smi(["--query-gpu=" + FIELDS, "--format=csv,noheader,nounits"])
        procs = {}
        try:
            for row in smi(
                ["--query-compute-apps=gpu_uuid,pid,used_memory", "--format=csv,noheader,nounits"]
            ):
                if len(row) >= 3:
                    procs.setdefault(row[0], []).append(num(row[2]))
        except Exception:  # compute-apps is optional detail
            pass
    except Exception:
        errors += 1
        rows, procs = [], {}
        lines.append("# HELP gpu_smi_query_errors_total " + HELP["gpu_smi_query_errors_total"])
        lines.append("# TYPE gpu_smi_query_errors_total counter")
        lines.append(f"gpu_smi_query_errors_total {errors}")
        return "\n".join(lines) + "\n"

    # One HELP/TYPE pair per metric name, before any sample: Prometheus 3.x
    # rejects repeated metadata and any type it does not know.
    for metric, help_text in HELP.items():
        lines.append(f"# HELP {metric} {help_text}")
        lines.append(f"# TYPE {metric} {TYPE[metric]}")

    for row in rows:
        if len(row) < len(FIELDS.split(",")):
            continue
        idx, name, uuid, driver, mem_total, mem_used, mem_free, util_gpu, util_mem, temp, power = row[:11]
        labels = f'gpu="{idx}", name="{name}", uuid="{uuid}", driver_version="{driver}"'
        lines.append(f'gpu_info{{{labels}}} 1')
        # nvidia-smi reports memory in MiB (--nounits); the metric names say
        # bytes, so the byte-valued ones are converted before emitting.
        for metric, raw in (
            ("gpu_memory_total_bytes", mem_total),
            ("gpu_memory_used_bytes", mem_used),
            ("gpu_memory_free_bytes", mem_free),
            ("gpu_utilization_percent", util_gpu),
            ("gpu_memory_utilization_percent", util_mem),
            ("gpu_temperature_celsius", temp),
            ("gpu_power_draw_watts", power),
        ):
            value = num(raw)
            if value is None:
                continue  # nvidia-smi reported [N/A]
            if metric.endswith("_bytes"):
                value *= MIB
            lines.append(f"{metric}{{{labels}}} {value}")

        count = len(procs.get(uuid, []))
        lines.append(f"gpu_compute_processes{{{labels}}} {count}")
        for pid, mem in enumerate(procs.get(uuid, [])):
            if mem is not None:
                lines.append(f'gpu_compute_process_memory_mib{{{labels}, pid="{pid}"}} {mem}')

    lines.append("gpu_exporter_up 1")
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] == "/metrics":
            body = render().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        body = b"gpu_exporter\n  GET /metrics\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):  # quiet
        sys.stderr.write("gpu_exporter: " + fmt % args + "\n")


def main():
    if not os.path.exists(NVIDIA_SMI):
        sys.exit(f"nvidia-smi not found at {NVIDIA_SMI}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
