#!/usr/bin/env python3
"""Render the Grafana dashboards that obs-stack ships.

Panel definitions live here as data instead of raw JSON so the four dashboards
stay consistent (same datasource variables, same colour rules, same layout).
scripts/deploy.sh runs this generator and ships the result to Grafana as
ConfigMaps labelled grafana_dashboard: "1".

Datasource variables:
  ${DS_PROMETHEUS} -> the "prometheus" datasource created by kube-prometheus-stack
  ${DS_LOKI}       -> the "loki" datasource created by grafana.additionalDataSources
"""

import json
import os
import sys

OUT_DIR = os.environ.get("OBS_DASH_DIR") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "monitoring", "dashboards"
)

DS = {"name": "${DS_PROMETHEUS}"}
DS_LOG = {"name": "${DS_LOKI}"}


def thr(steps=None, base="red"):
    """Grafana thresholds; the first step has to be open-ended.

    ``base`` is the colour below the first numeric threshold, so metrics where a
    low value is good (clock drift, free space) get ``base="green"`` and rising
    thresholds instead of the default "anything is red until it turns green".
    """
    out = [{"color": base, "value": None}]
    for color, value in steps or [("green", 1)]:
        out.append({"color": color, "value": value})
    return {"mode": "absolute", "steps": out}


def target(expr, ref="A", instant=False, legend=None, fmt=None):
    t = {"refId": ref, "expr": expr}
    if instant:
        t["instant"] = True
    if legend:
        t["legendFormat"] = legend
    if fmt:
        t["format"] = fmt
    return t


def row(title, y):
    return {
        "type": "row",
        "title": title,
        "gridPos": {"h": 1, "w": 24, "x": 0, "y": y},
        "collapsed": False,
        "panels": [],
    }


def panel(type_, id_, title, targets, x, y, w=12, h=8, unit="short",
          min_=None, max_=None, steps=None, base="red", ds=DS, options=None,
          custom=None, transforms=None, fieldOverrides=None):
    defaults = {"unit": unit, "thresholds": thr(steps, base)}
    if min_ is not None:
        defaults["min"] = min_
    if max_ is not None:
        defaults["max"] = max_
    if custom:
        defaults["custom"] = custom
    return {
        "id": id_,
        "type": type_,
        "title": title,
        "datasource": ds,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": targets,
        "fieldConfig": {
            "defaults": defaults,
            "overrides": fieldOverrides or [],
        },
        "options": options or {},
        "transforms": transforms or [],
    }


def stat(id_, title, expr, x, y, w=6, h=4, unit="short", steps=None, legend=None, base="red"):
    return panel("stat", id_, title, [target(expr, instant=True, legend=legend)],
                 x, y, w=w, h=h, unit=unit, steps=steps, base=base,
                 options={"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                          "colorMode": "value", "graphMode": "none"})


def gauge(id_, title, expr, x, y, w=6, h=4, unit="percent", min_=0, max_=100, steps=None, legend=None, base="red"):
    return panel("gauge", id_, title, [target(expr, instant=True, legend=legend)],
                 x, y, w=w, h=h, unit=unit, min_=min_, max_=max_, steps=steps, base=base,
                 options={"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
                 custom={"thresholdsMode": "absolute", "showThresholdLabels": False})


def timeseries(id_, title, targets, x, y, w=12, h=8, unit="short", min_=None,
               max_=None, steps=None, base="red", fill=15):
    return panel("timeseries", id_, title, targets, x, y, w=w, h=h, unit=unit,
                 min_=min_, max_=max_, steps=steps, base=base,
                 custom={"fillOpacity": fill, "lineWidth": 1, "showLegend": True})


def table(id_, title, expr, x, y, w=12, h=8, unit="short"):
    return panel("table", id_, title, [target(expr, instant=True, fmt="table")],
                 x, y, w=w, h=h, unit=unit,
                 options={"showLegend": False})


def logs(id_, title, expr, x, y, w=24, h=8):
    return panel("logs", id_, title, [target(expr)], x, y, w=w, h=h, ds=DS_LOG,
                 options={"showTimeRange": False})


def text(id_, title, body, x, y, w=24, h=3):
    return panel("text", id_, title, [], x, y, w=w, h=h,
                 options={"mode": "markdown", "content": body})


def dashboard(uid, title, tags, panels):
    return {
        "annotations": {"list": []},
        "editable": True,
        "graphTooltip": 1,
        "id": None,
        "tags": tags,
        "title": title,
        "uid": uid,
        "schemaVersion": 39,
        "time": {"from": "now-3h", "to": "now"},
        "refresh": "30s",
        "templating": {"list": [
            {"name": "DS_PROMETHEUS", "label": "Prometheus", "type": "datasource",
             "query": "prometheus", "hide": 0},
            {"name": "DS_LOKI", "label": "Loki", "type": "datasource",
             "query": "loki", "hide": 0},
        ]},
        "panels": panels,
    }


# --------------------------------------------------------------------------
# Windows host (windows_exporter, job="windows-host")
# --------------------------------------------------------------------------
W = 'job="windows-host"'

WINDOWS = dashboard("obs-windows-host", "Windows host", ["obs-stack", "host", "windows"], [
    row("Health", 0),
    stat(1, "windows_exporter up", f"up{{{W}}}", 0, 1, w=4),
    gauge(2, "CPU utilisation",
          '100 * sum(rate(windows_cpu_time_total{mode!="idle"}[5m])) / sum(rate(windows_cpu_time_total[5m]))',
          4, 1, steps=[("orange", 70), ("red", 90)]),
    gauge(3, "Memory in use",
          "100 * (windows_memory_physical_total_bytes - windows_memory_available_bytes) / windows_memory_physical_total_bytes",
          9, 1, steps=[("orange", 70), ("red", 90)]),
    gauge(4, "Commit charge",
          "100 * windows_memory_committed_bytes / windows_memory_commit_limit",
          14, 1, steps=[("orange", 70), ("red", 90)]),
    stat(5, "Clock drift", "abs(windows_time_computed_time_offset_seconds)", 19, 1,
         unit="s", base="green", steps=[("orange", 1), ("red", 30)]),

    row("CPU", 5),
    timeseries(6, "CPU time by mode", [
        target("rate(windows_cpu_time_total[5m])", legend="{{mode}}"),
    ], 0, 6, unit="s"),
    timeseries(7, "Busy per core", [
        target('100 * (1 - rate(windows_cpu_time_total{mode="idle"}[5m]) / rate(windows_cpu_time_total[5m]))',
               legend="{{core}}"),
    ], 12, 6, unit="percent", min_=0, max_=100),
    timeseries(8, "Interrupts and DPCs", [
        target(f"rate(windows_cpu_interrupts_total{{{W}}}[5m])", legend="{{core}} interrupts"),
        target(f"rate(windows_cpu_dpcs_total{{{W}}}[5m])", legend="{{core}} dpc"),
    ], 0, 14, unit="short"),
    timeseries(9, "Processor queue length", [
        target("windows_system_processor_queue_length", legend="queue"),
        target("rate(windows_system_system_calls_total[5m])", legend="syscalls/s"),
    ], 12, 14, unit="short"),

    row("Memory", 22),
    gauge(10, "Physical in use",
          "windows_memory_physical_total_bytes - windows_memory_available_bytes",
          0, 23, w=6, unit="bytes", min_=0, max_=None, steps=[]),
    gauge(11, "Physical available", "windows_memory_available_bytes",
          6, 23, w=6, unit="bytes", min_=0, max_=None, steps=[]),
    gauge(12, "Committed", "windows_memory_committed_bytes",
          12, 23, w=6, unit="bytes", min_=0, max_=None, steps=[]),
    stat(13, "Pagefile free", "sum(windows_pagefile_free_bytes)", 18, 23,
         unit="bytes", base="green", steps=[("orange", 1_000_000_000), ("red", 300_000_000)]),
    timeseries(14, "Page faults", [
        target("rate(windows_memory_page_faults_total[5m])", legend="hard faults/s"),
        target("rate(windows_memory_transition_faults_total[5m])", legend="transition faults/s"),
    ], 0, 27, unit="short"),
    timeseries(15, "Swap page traffic", [
        target("rate(windows_memory_swap_page_reads_total[5m])", legend="reads/s"),
        target("rate(windows_memory_swap_page_writes_total[5m])", legend="writes/s"),
    ], 12, 27, unit="short"),

    row("Disk", 35),
    timeseries(16, "Logical volume free", [
        target("100 * windows_logical_disk_free_bytes / windows_logical_disk_size_bytes",
               legend="{{volume}}"),
    ], 0, 36, unit="percent", min_=0, max_=100, base="green",
        steps=[("orange", 20), ("green", 50)]),
    timeseries(17, "Logical throughput", [
        target("rate(windows_logical_disk_read_bytes_total[5m])", legend="{{volume}} read"),
        target("rate(windows_logical_disk_write_bytes_total[5m])", legend="{{volume}} write"),
    ], 12, 36, unit="Bps"),
    timeseries(18, "Physical disk busy", [
        target("100 * rate(windows_physical_disk_read_seconds_total[5m])", legend="{{disk}} read"),
        target("100 * rate(windows_physical_disk_write_seconds_total[5m])", legend="{{disk}} write"),
    ], 0, 44, unit="percent", min_=0, max_=100),
    timeseries(19, "Physical disk IO/s", [
        target("rate(windows_physical_disk_reads_total[5m])", legend="{{disk}} reads"),
        target("rate(windows_physical_disk_writes_total[5m])", legend="{{disk}} writes"),
    ], 12, 44, unit="short"),

    row("Network and TCP", 52),
    timeseries(20, "Throughput", [
        target("rate(windows_net_bytes_received_total[5m])", legend="{{nic}} rx"),
        target("rate(windows_net_bytes_sent_total[5m])", legend="{{nic}} tx"),
    ], 0, 53, unit="Bps"),
    timeseries(21, "Errors and drops", [
        target("rate(windows_net_packets_received_errors_total[5m])", legend="{{nic}} rx errors"),
        target("rate(windows_net_packets_outbound_errors_total[5m])", legend="{{nic}} tx errors"),
        target("rate(windows_net_output_queue_length_packets[5m])", legend="{{nic}} queue"),
    ], 12, 53, unit="short"),
    timeseries(22, "TCP connections", [
        target("windows_tcp_connections_state_count", legend="{{af}} {{state}}"),
    ], 0, 61, unit="short"),
    timeseries(23, "TCP retransmits", [
        target("rate(windows_tcp_segments_retransmitted_total[5m])", legend="retransmits/s"),
        target("rate(windows_tcp_connection_failures_total[5m])", legend="failed connects/s"),
    ], 12, 61, unit="short"),

    row("Processes and services", 69),
    table(24, "Top processes by CPU",
          'topk(10, sum by (process) (rate(windows_process_cpu_time_total{mode!="idle"}[5m]))) * 100',
          0, 70, unit="percent"),
    table(25, "Top processes by working set",
          "topk(10, windows_process_working_set_bytes)", 12, 70, unit="bytes"),
    table(26, "Services not running",
          'windows_service_state{state!="running"} == 1', 0, 78, unit="short"),
    stat(27, "Processes", "windows_system_processes", 12, 78, base="green",
         steps=[("orange", 400), ("red", 700)]),
    stat(28, "Threads", "windows_system_threads", 18, 78, base="green",
         steps=[("orange", 2000), ("red", 4000)]),

    row("Exporter internals", 86),
    stat(29, "Collectors failing", f"count(windows_exporter_collector_success{{{W}}}) - sum(windows_exporter_collector_success{{{W}}})",
         0, 87, base="green", steps=[("orange", 1), ("red", 3)]),
    stat(30, "Collectors total", f"count(windows_exporter_collector_success{{{W}}})", 6, 87, base="green"),
    timeseries(31, "Scrape cost", [
        target(f"rate(promhttp_metric_handler_requests_total{{{W}}}[5m])", legend="{{code}} req/s"),
        # windows_exporter exposes this as a plain gauge of the most recent
        # scrape, not a _sum/_count histogram, so rate() over _sum has no data.
        target(f"windows_exporter_scrape_duration_seconds{{{W}}}", legend="last scrape seconds"),
    ], 12, 87, unit="short"),
    text(32, "Windows event logs",
         "Windows event logs are **out of scope**: `windows_exporter` does not expose the event log "
         "API and no Windows-side log shipper is deployed. WSL and pod logs are in the WSL host and "
         "cluster dashboards.", 0, 95),
])


# --------------------------------------------------------------------------
# WSL distro (node_exporter, job="wsl-host"; host promtail, job="wsl-promtail")
# --------------------------------------------------------------------------
WSL = dashboard("obs-wsl-host", "WSL distro", ["obs-stack", "host", "wsl"], [
    row("Health", 0),
    stat(1, "node_exporter up", 'up{job="wsl-host"}', 0, 1, w=4),
    gauge(2, "CPU utilisation",
          '100 * (1 - rate(node_cpu_seconds_total{mode="idle",job="wsl-host"}[5m]) / rate(node_cpu_seconds_total{job="wsl-host"}[5m]))',
          4, 1, steps=[("orange", 70), ("red", 90)]),
    gauge(3, "Memory in use",
          '100 * (1 - node_memory_MemAvailable_bytes{job="wsl-host"} / node_memory_MemTotal_bytes{job="wsl-host"})',
          9, 1, steps=[("orange", 70), ("red", 90)]),
    stat(4, "Swap in use",
         'node_memory_SwapTotal_bytes{job="wsl-host"} - node_memory_SwapFree_bytes{job="wsl-host"}',
         14, 1, unit="bytes", base="green", steps=[("orange", 1e9), ("red", 4e9)]),
    stat(5, "Failed systemd units",
         # Empty means "nothing failed", which Grafana renders as No data;
         # vector(0) keeps the panel showing a healthy 0.
         'count(node_systemd_unit_state{state="failed",job="wsl-host"}) or vector(0)',
         19, 1, base="green", steps=[("orange", 1), ("red", 5)]),

    row("CPU", 5),
    timeseries(6, "CPU time by mode", [
        target('rate(node_cpu_seconds_total{job="wsl-host"}[5m])', legend="{{mode}}"),
    ], 0, 6, unit="s"),
    timeseries(7, "Busy per core", [
        target('100 * (1 - rate(node_cpu_seconds_total{mode="idle",job="wsl-host"}[5m]) / rate(node_cpu_seconds_total{job="wsl-host"}[5m]))',
               legend="{{cpu}}"),
    ], 12, 6, unit="percent", min_=0, max_=100),
    timeseries(8, "Load average", [
        target('node_load1{job="wsl-host"}', legend="1m"),
        target('node_load5{job="wsl-host"}', legend="5m"),
        target('node_load15{job="wsl-host"}', legend="15m"),
    ], 0, 14, unit="short"),
    timeseries(9, "Scheduler activity", [
        target('rate(node_context_switches_total{job="wsl-host"}[5m])', legend="context switches/s"),
        target('rate(node_intr_total{job="wsl-host"}[5m])', legend="interrupts/s"),
        target('rate(node_forks_total{job="wsl-host"}[5m])', legend="forks/s"),
    ], 12, 14, unit="short"),

    row("Memory", 22),
    gauge(10, "Total RAM", 'node_memory_MemTotal_bytes{job="wsl-host"}',
          0, 23, w=6, unit="bytes", min_=0, max_=None, steps=[]),
    gauge(11, "Available", 'node_memory_MemAvailable_bytes{job="wsl-host"}',
          6, 23, w=6, unit="bytes", min_=0, max_=None, steps=[]),
    gauge(12, "Committed (AS)", 'node_memory_Committed_AS_bytes{job="wsl-host"}',
          12, 23, w=6, unit="bytes", min_=0, max_=None, steps=[]),
    gauge(13, "Slab + kernel",
          'node_memory_Slab_bytes{job="wsl-host"} + node_memory_KernelStack_bytes{job="wsl-host"}',
          18, 23, w=6, unit="bytes", min_=0, max_=None, steps=[]),
    timeseries(14, "Cache and reclaimable", [
        target('node_memory_Cached_bytes{job="wsl-host"}', legend="page cache"),
        target('node_memory_Buffers_bytes{job="wsl-host"}', legend="buffers"),
        target('node_memory_SReclaimable_bytes{job="wsl-host"}', legend="slab reclaimable"),
    ], 0, 27, unit="bytes"),
    timeseries(15, "Dirty and writeback", [
        target('node_memory_Dirty_bytes{job="wsl-host"}', legend="dirty"),
        target('node_memory_Writeback_bytes{job="wsl-host"}', legend="writeback"),
    ], 12, 27, unit="bytes"),

    row("Filesystem", 35),
    timeseries(16, "Free space", [
        target('100 * node_filesystem_avail_bytes{job="wsl-host",fstype!="tmpfs"} / node_filesystem_size_bytes{job="wsl-host",fstype!="tmpfs"}',
               legend="{{mountpoint}}"),
    ], 0, 36, unit="percent", min_=0, max_=100, base="green",
        steps=[("orange", 15), ("green", 40)]),
    timeseries(17, "Inodes used", [
        target('100 * (1 - node_filesystem_files_free{job="wsl-host",fstype!="tmpfs"} / node_filesystem_files{job="wsl-host",fstype!="tmpfs"})',
               legend="{{mountpoint}}"),
    ], 12, 36, unit="percent", min_=0, max_=100),
    table(18, "Mounts", 'node_filesystem_avail_bytes{job="wsl-host",fstype!="tmpfs"}',
          0, 44, unit="bytes"),

    row("Disk IO", 52),
    timeseries(19, "Busy per device", [
        target('100 * rate(node_disk_io_time_seconds_total{job="wsl-host"}[5m])', legend="{{device}}"),
        target('100 * rate(node_disk_io_time_weighted_seconds_total{job="wsl-host"}[5m])',
               legend="{{device}} queue avg"),
    ], 0, 53, unit="percent", min_=0, max_=100),
    timeseries(20, "Throughput", [
        target('rate(node_disk_read_bytes_total{job="wsl-host"}[5m])', legend="{{device}} read"),
        target('rate(node_disk_written_bytes_total{job="wsl-host"}[5m])', legend="{{device}} write"),
    ], 12, 53, unit="Bps"),
    timeseries(21, "Operations", [
        target('rate(node_disk_reads_completed_total{job="wsl-host"}[5m])', legend="{{device}} reads"),
        target('rate(node_disk_writes_completed_total{job="wsl-host"}[5m])', legend="{{device}} writes"),
    ], 0, 61, unit="short"),

    row("Network", 69),
    timeseries(22, "Throughput", [
        target('rate(node_network_receive_bytes_total{job="wsl-host",device!~"lo"}[5m])', legend="{{device}} rx"),
        target('rate(node_network_transmit_bytes_total{job="wsl-host",device!~"lo"}[5m])', legend="{{device}} tx"),
    ], 0, 70, unit="Bps"),
    timeseries(23, "Drops and errors", [
        target('rate(node_network_receive_drop_total{job="wsl-host",device!~"lo"}[5m])', legend="{{device}} rx drops"),
        target('rate(node_network_transmit_drop_total{job="wsl-host",device!~"lo"}[5m])', legend="{{device}} tx drops"),
        target('rate(node_network_receive_errs_total{job="wsl-host",device!~"lo"}[5m])', legend="{{device}} rx errs"),
        target('rate(node_softnet_dropped_total{job="wsl-host"}[5m])', legend="softnet dropped"),
    ], 12, 70, unit="short"),
    timeseries(24, "TCP connections", [
        target('node_tcp_connection_states{job="wsl-host"}', legend="{{state}}"),
        target('node_netstat_Tcp_CurrEstab{job="wsl-host"}', legend="established (netstat)"),
    ], 0, 78, unit="short"),
    timeseries(25, "TCP health", [
        target('rate(node_netstat_Tcp_RetransSegs{job="wsl-host"}[5m])', legend="retransmits/s"),
        target('rate(node_netstat_TcpExt_TCPSynRetrans{job="wsl-host"}[5m])', legend="syn retransmits/s"),
        target('rate(node_netstat_TcpExt_ListenOverflows{job="wsl-host"}[5m])', legend="listen overflows/s"),
    ], 12, 78, unit="short"),

    row("System", 86),
    timeseries(26, "File descriptors", [
        target('node_filefd_allocated{job="wsl-host"}', legend="allocated"),
        target('node_filefd_maximum{job="wsl-host"}', legend="maximum"),
    ], 0, 87, unit="short"),
    timeseries(27, "Entropy and softnet", [
        target('node_entropy_available_bits{job="wsl-host"}', legend="entropy bits"),
        target('rate(node_softnet_times_squeezed_total{job="wsl-host"}[5m])', legend="squeezed/s"),
    ], 12, 87, unit="short"),
    table(28, "Failed units", 'node_systemd_unit_state{state="failed",job="wsl-host"} == 1', 0, 95),
    stat(29, "Uptime", 'time() - node_boot_time_seconds{job="wsl-host"}', 12, 95,
         unit="s", base="green", steps=[("green", 1)]),

    row("Log shipping (promtail on WSL)", 100),
    stat(30, "promtail up", 'up{job="wsl-promtail"}', 0, 101, w=4),
    timeseries(31, "Entries sent", [
        target('rate(promtail_sent_entries_total{job="wsl-promtail"}[5m])', legend="entries/s"),
        target('rate(promtail_sent_bytes_total{job="wsl-promtail"}[5m])', legend="bytes/s"),
    ], 4, 101, w=10, unit="short"),
    timeseries(32, "Targets and failures", [
        target('promtail_targets_active_total{job="wsl-promtail"}', legend="active targets"),
        target('promtail_files_active_total{job="wsl-promtail"}', legend="open files"),
        target('rate(promtail_config_reload_fail_total{job="wsl-promtail"}[5m])', legend="reload failures/s"),
    ], 14, 101, w=10, unit="short"),
    logs(33, "journald errors", '{job="wsl-journald"} |= "error"', 0, 109),
    logs(34, "distro log files", '{job="wsl-files"} |= "error"', 0, 117),
    text(35, "Note",
         "journald is shipped by the `obs-journal-follow` unit (journald cannot be tailed directly), "
         "so its records reach Loki as JSON lines tagged `job=\"wsl-journald\"`. Windows event logs "
         "are out of scope.", 0, 125),
])


# --------------------------------------------------------------------------
# GPU (nvidia-smi exporter on WSL, job="wsl-gpu")
# --------------------------------------------------------------------------
G = 'job="wsl-gpu"'

GPU = dashboard("obs-gpu", "GPU (RTX via nvidia-smi)", ["obs-stack", "host", "gpu"], [
    row("Health", 0),
    stat(1, "scrape up", f'up{{{G}}}', 0, 1, w=4),
    stat(2, "exporter up", f'gpu_exporter_up{{{G}}}', 4, 1, w=4),
    gauge(3, "GPU utilisation", f'gpu_utilization_percent{{{G}}}', 8, 1, w=4,
          steps=[("orange", 70), ("red", 90)], legend="{{gpu}}"),
    gauge(4, "VRAM in use", f'gpu_memory_utilization_percent{{{G}}}', 12, 1, w=4,
          steps=[("orange", 70), ("red", 90)], legend="{{gpu}}"),
    stat(5, "Temperature", f'gpu_temperature_celsius{{{G}}}', 16, 1, w=4,
         unit="celsius", base="green", steps=[("orange", 60), ("red", 85)]),
    stat(6, "Power draw", f'gpu_power_draw_watts{{{G}}}', 20, 1, w=4,
         unit="watts", base="green", steps=[("orange", 120), ("red", 220)]),

    row("Memory", 5),
    gauge(7, "VRAM total", f'gpu_memory_total_bytes{{{G}}}', 0, 6, w=6,
          unit="bytes", max_=None, steps=[]),
    gauge(8, "VRAM used", f'gpu_memory_used_bytes{{{G}}}', 6, 6, w=6,
          unit="bytes", max_=None, steps=[]),
    gauge(9, "VRAM free", f'gpu_memory_free_bytes{{{G}}}', 12, 6, w=6,
          unit="bytes", max_=None, steps=[]),
    gauge(10, "Held by processes",
          # No compute process (or memory nvidia-smi cannot read from WSL) means
          # an empty result, which renders as No data; vector(0) shows 0 instead.
          f'1048576 * sum(gpu_compute_process_memory_mib{{{G}}}) or vector(0)', 18, 6, w=6,
          unit="bytes", max_=None, steps=[]),
    timeseries(11, "VRAM used over time", [
        target(f'gpu_memory_used_bytes{{{G}}}', legend="{{gpu}}"),
        target(f'gpu_memory_total_bytes{{{G}}}', legend="{{gpu}} total"),
    ], 0, 10, unit="bytes"),
    timeseries(12, "Utilisation", [
        target(f'gpu_utilization_percent{{{G}}}', legend="{{gpu}} core"),
        target(f'gpu_memory_utilization_percent{{{G}}}', legend="{{gpu}} memory"),
    ], 12, 10, unit="percent", min_=0, max_=100),

    row("Thermals and processes", 18),
    timeseries(13, "Temperature", [
        target(f'gpu_temperature_celsius{{{G}}}', legend="{{gpu}}"),
    ], 0, 19, unit="celsius", min_=0, base="green", steps=[("orange", 60), ("red", 85)]),
    timeseries(14, "Power draw", [
        target(f'gpu_power_draw_watts{{{G}}}', legend="{{gpu}}"),
    ], 8, 19, unit="watts", min_=0, base="green", steps=[("orange", 120), ("red", 220)]),
    timeseries(15, "Compute processes", [
        target(f'gpu_compute_processes{{{G}}}', legend="{{gpu}}"),
    ], 16, 19, w=8),
    timeseries(16, "Memory held per process", [
        target(f'gpu_compute_process_memory_mib{{{G}}}', legend="{{gpu}} pid {{pid}}"),
    ], 0, 27, w=12, unit="mbytes", min_=0),
    table(17, "GPU inventory", f'gpu_info{{{G}}}', 12, 27, w=12),

    row("Exporter internals", 35),
    timeseries(18, "nvidia-smi failures", [
        target(f'rate(gpu_smi_query_errors_total{{{G}}}[5m])', legend="errors/s"),
        target(f'gpu_smi_query_errors_total{{{G}}}', legend="errors total"),
    ], 0, 36, w=8),
    stat(19, "Query errors", f'gpu_smi_query_errors_total{{{G}}}', 8, 36, w=4,
         base="green", steps=[("orange", 1), ("red", 10)]),
    logs(20, "Exporter log (journald)", '{job="wsl-journald"} |= "gpu_exporter"', 12, 36, w=12),
    text(21, "Note",
         f"GPU metrics come from `exporters/gpu/gpu_exporter.py` running on WSL against "
         f"`/usr/lib/wsl/lib/nvidia-smi`, so they describe the Windows GPU through WSL's "
         f"passthrough. `windows_exporter`'s own `gpu` collector reports nothing on WSL2 "
         f"hosts, which is why this exporter exists. Per-process memory is only emitted when "
         f"nvidia-smi can read it; under WSL it reports `[N/A]` for Windows-side processes, "
         f"so 'Memory held per process' is normally empty while 'Compute processes' still counts them.", 0, 44),
])


# --------------------------------------------------------------------------
# Kubernetes cluster (in-cluster exporters: node-exporter, kubelet/cadvisor,
# kube-state-metrics, apiserver, etcd; pod logs via the promtail DaemonSet)
# --------------------------------------------------------------------------
# kube-prometheus-stack scrapes in-cluster components through ServiceMonitors,
# and prometheus-operator derives the `job` label from the ServiceMonitor name
# (something like "serviceMonitor/monitoring/obs-prometheus-node-exporter/0"),
# so these match on a substring rather than an exact job name. They also keep
# the WSL host node_exporter (job="wsl-host") out of the cluster panels, which
# matters because both exporters emit the same `node_*` metric names.
NE = 'job=~".*node-exporter.*"'
KSM = 'job=~".*kube-state-metrics.*"'
CV = 'job=~".*kubelet.*",container!=""'

CLUSTER = dashboard("obs-cluster", "Cluster overview", ["obs-stack", "cluster", "kubernetes"], [
    row("Health", 0),
    stat(1, "node-exporter up", f'up{{{NE}}}', 0, 1, w=4),
    stat(2, "Nodes ready",
         f'sum(kube_node_status_condition{{{KSM},condition="Ready",status="true"}})',
         4, 1, steps=[("green", 1)]),
    stat(3, "Pod CPU",
         f'sum(rate(container_cpu_usage_seconds_total{{{CV}}}[5m]))', 8, 1, w=4),
    stat(4, "Pod memory",
         f'sum(container_memory_working_set_bytes{{{CV}}})', 12, 1, w=4, unit="bytes"),
    stat(5, "Containers running",
         f'sum(kube_pod_container_status_running{{{KSM}}})', 16, 1, w=4,
         steps=[("green", 1)]),
    stat(6, "Containers not ready",
         f'count(kube_pod_container_status_ready{{{KSM}}} == 0) or vector(0)', 20, 1, w=4,
         base="green", steps=[("orange", 1), ("red", 3)]),

    row("Nodes", 5),
    timeseries(7, "CPU busy", [
        target(f'100 * (1 - sum by (instance) (rate(node_cpu_seconds_total{{mode="idle",{NE}}}[5m])) '
               f'/ sum by (instance) (rate(node_cpu_seconds_total{{{NE}}}[5m])))', legend="{{instance}}"),
    ], 0, 6, unit="percent", min_=0, max_=100, steps=[("orange", 70), ("red", 90)]),
    timeseries(8, "Memory in use", [
        target(f'100 * (1 - node_memory_MemAvailable_bytes{{{NE}}} / node_memory_MemTotal_bytes{{{NE}}})',
               legend="{{instance}}"),
    ], 12, 6, unit="percent", min_=0, max_=100, steps=[("orange", 70), ("red", 90)]),
    timeseries(9, "Filesystem free", [
        target(f'100 * node_filesystem_avail_bytes{{{NE},fstype!="tmpfs"}} / '
               f'node_filesystem_size_bytes{{{NE},fstype!="tmpfs"}}', legend="{{instance}} {{mountpoint}}"),
    ], 0, 14, unit="percent", min_=0, max_=100, base="green",
        steps=[("orange", 15), ("green", 40)]),
    timeseries(10, "Disk busy", [
        target(f'100 * rate(node_disk_io_time_seconds_total{{{NE}}}[5m])', legend="{{instance}} {{device}}"),
    ], 12, 14, unit="percent", min_=0, max_=100),
    timeseries(11, "Network", [
        target(f'rate(node_network_receive_bytes_total{{{NE},device!~"lo"}}[5m])', legend="{{instance}} {{device}} rx"),
        target(f'rate(node_network_transmit_bytes_total{{{NE},device!~"lo"}}[5m])', legend="{{instance}} {{device}} tx"),
    ], 0, 22, unit="Bps"),
    timeseries(12, "Load average", [
        target(f'node_load1{{{NE}}}', legend="{{instance}} 1m"),
        target(f'node_load5{{{NE}}}', legend="{{instance}} 5m"),
        target(f'node_load15{{{NE}}}', legend="{{instance}} 15m"),
    ], 12, 22),

    row("Workloads", 30),
    timeseries(13, "CPU per pod", [
        target(f'sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{{{CV}}}[5m]))',
               legend="{{namespace}}/{{pod}}"),
    ], 0, 31),
    timeseries(14, "Memory per pod", [
        target(f'sum by (namespace, pod) (container_memory_working_set_bytes{{{CV}}})',
               legend="{{namespace}}/{{pod}}"),
    ], 12, 31, unit="bytes"),
    timeseries(15, "Restarts in 15m", [
        target(f'increase(kube_pod_container_status_restarts_total{{{KSM}}}[15m])',
               legend="{{namespace}}/{{pod}}"),
    ], 0, 39, base="green", steps=[("orange", 1), ("red", 5)]),
    timeseries(16, "Pod phases", [
        target(f'sum by (phase) (kube_pod_status_phase{{{KSM}}})', legend="{{phase}}"),
    ], 12, 39),
    timeseries(17, "Pod network", [
        target(f'sum by (pod) (rate(container_network_receive_bytes_total{{job=~".*kubelet.*"}}[5m]))',
               legend="{{pod}} rx"),
        target(f'sum by (pod) (rate(container_network_transmit_bytes_total{{job=~".*kubelet.*"}}[5m]))',
               legend="{{pod}} tx"),
    ], 0, 47, unit="Bps"),
    table(18, "Containers not ready",
          f'kube_pod_container_status_ready{{{KSM}}} == 0', 12, 47),

    row("Control plane", 55),
    timeseries(19, "API requests", [
        target('rate(apiserver_request_total{job=~".*apiserver.*"}[5m])', legend="{{verb}} {{code}}"),
    ], 0, 56, w=8),
    timeseries(20, "API server errors", [
        target('sum(rate(apiserver_request_total{job=~".*apiserver.*",code=~"5.."}[5m]))', legend="5xx/s"),
        target('rate(apiserver_request_duration_seconds_sum{job=~".*apiserver.*"}[5m])', legend="latency sum/s"),
    ], 8, 56, w=8),
    gauge(21, "etcd has leader", 'etcd_server_has_leader{job=~".*kube-etcd.*"}', 16, 56, w=4,
          max_=1, steps=[("green", 1)], legend="{{job}}"),
    timeseries(22, "etcd fsync", [
        # etcd exposes the fsync metric only as a histogram, so the bare name
        # has no series; derive a quantile from the bucket.
        target('histogram_quantile(0.99, sum by (le) (rate(etcd_disk_wal_fsync_duration_seconds_bucket{job=~".*kube-etcd.*"}[5m])))',
               legend="{{quantile}}"),
    ], 0, 64, w=8, unit="s"),
    timeseries(23, "Cluster jobs up", [
        target('up{job=~".*apiserver.*|.*kube-etcd.*|.*kubelet.*|.*kube-state-metrics.*|.*node-exporter.*|.*coredns.*"}',
               legend="{{job}} {{instance}}"),
    ], 8, 64, w=8),
    table(24, "All scrape targets",
          'up{job=~"windows-host|wsl-host|wsl-gpu|wsl-promtail|edge-prometheus|'
          '.*node-exporter.*|.*kubelet.*|.*kube-state-metrics.*|.*apiserver.*|.*kube-etcd.*|'
          '.*coredns.*|.*prometheus.*|.*alertmanager.*|.*grafana.*|.*loki.*|.*promtail.*|.*operator.*"}',
          16, 64, w=8),

    row("Monitoring stack", 72),
    gauge(25, "Prometheus", 'up{job=~".*prometheus.*"}', 0, 73, w=4,
          max_=1, steps=[("green", 1)], legend="{{job}}"),
    gauge(26, "Grafana", 'up{job=~".*grafana.*"}', 4, 73, w=4,
          max_=1, steps=[("green", 1)], legend="{{job}}"),
    gauge(27, "Alertmanager", 'up{job=~".*alertmanager.*"}', 8, 73, w=4,
          max_=1, steps=[("green", 1)], legend="{{job}}"),
    gauge(28, "Loki", 'up{job=~".*loki.*"}', 12, 73, w=4,
          max_=1, steps=[("green", 1)], legend="{{job}}"),
    gauge(29, "Promtail", 'up{job=~".*promtail.*"}', 16, 73, w=4,
          max_=1, steps=[("green", 1)], legend="{{job}}"),
    stat(30, "Alerts firing", 'count(ALERTS{alertstate="firing"}) or vector(0)', 20, 73, w=4,
         base="green", steps=[("orange", 1), ("red", 4)]),

    row("Alerts and logs", 77),
    timeseries(31, "Firing alerts", [
        target('count by (alertname, severity) (ALERTS{alertstate="firing"})',
               legend="{{alertname}} ({{severity}})"),
    ], 0, 78, base="green", steps=[("orange", 1), ("red", 4)]),
    timeseries(32, "Prometheus health", [
        target('rate(prometheus_rule_evaluation_failures_total[5m])', legend="rule eval failures/s"),
        # Per-target scrape bookkeeping is exposed as scrape_series_added;
        # prometheus_scrape_series_added_total does not exist in Prometheus v3.
        target('sum(rate(scrape_series_added[5m]))', legend="series added/s"),
        target('prometheus_tsdb_head_series', legend="head series"),
    ], 12, 78),
    logs(33, "Monitoring pod logs", '{job=~"monitoring/.*"} |= "error"', 0, 86),
    # Loki rejects matchers that can match the empty string (a negated matcher
    # alone is one), so select the pod-derived jobs by their namespace/name form
    # instead of excluding the host streams.
    logs(34, "Cluster pod logs", '{job=~"^.+/.+$"} |= "error"', 0, 94),
    text(35, "Note",
         "Pod logs are labelled `job=<namespace>/<app>` by the promtail DaemonSet. kind's "
         "control-plane components run as processes on the control-plane node, so their logs "
         "are not in `/var/log/pods` and only reach Loki through the WSL journald stream on the "
         "WSL host dashboard.", 0, 102),
])


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for dash in (WINDOWS, WSL, GPU, CLUSTER):
        path = os.path.join(OUT_DIR, dash["uid"] + ".json")
        with open(path, "w") as fh:
            json.dump(dash, fh, indent=2, sort_keys=True)
            fh.write("\n")
        print(f"wrote {path} ({len(dash['panels'])} panels)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
