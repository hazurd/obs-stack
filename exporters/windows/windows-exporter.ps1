# Starts / stops / inspects windows_exporter on the Windows host.
# Invoked from WSL: powershell.exe -NoProfile -ExecutionPolicy Bypass -File <this file> -Action start
param(
    [ValidateSet("start", "stop", "status", "scrape")] [string]$Action = "start",
    [string]$Exe = "C:\obs-stack\windows_exporter.exe",
    [string]$Source = "",
    [int]$Port = 9182,
    # 0.31.9 has no "diskio" or "perfmon" collector; disk I/O ships with
    # logical_disk / physical_disk. GPU metrics come from exporters/gpu instead.
    [string]$Collectors = "cpu,cpu_info,memory,logical_disk,physical_disk,net,os,service,process,system,time,tcp,pagefile",
    [string]$PidFile = "C:\obs-stack\windows_exporter.pid"
)

$ErrorActionPreference = "Stop"

function Listener([int]$port) {
    Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Running() {
    Get-Process -Name "windows_exporter" -ErrorAction SilentlyContinue
}

switch ($Action) {
    "start" {
        if ($Source -and -not (Test-Path $Exe)) {
            New-Item -ItemType Directory -Force -Path (Split-Path $Exe) | Out-Null
            Copy-Item $Source $Exe
            Write-Output "installed: $Exe"
        }
        if (-not (Test-Path $Exe)) { throw "windows_exporter.exe not found at $Exe" }

        $proc = Running | Where-Object { $_.Path -eq $Exe }
        if (-not $proc) {
            $proc = Start-Process -FilePath $Exe `
                -ArgumentList @("--collectors.enabled=$Collectors", "--web.listen-address=:$Port") `
                -WindowStyle Hidden -PassThru
            $proc.Id | Set-Content $PidFile
            Write-Output "started pid=$($proc.Id) port=$Port collectors=$Collectors"
        } else {
            Write-Output "already running pid=$($proc.Id) port=$Port"
        }

        # WSL reaches Windows through the NAT gateway, so inbound :9182 has to be
        # allowed. Requires elevation; skipped silently when not elevated.
        try {
            New-NetFirewallRule -DisplayName "obs-stack windows_exporter" `
                -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -ErrorAction Stop |
                Out-Null
            Write-Output "firewall: inbound rule added for tcp/$Port"
        } catch {
            Write-Output "firewall: skipped ($($_.Exception.Message))"
        }

        for ($i = 0; $i -lt 15; $i++) {
            if (Listener $Port) {
                Write-Output "ok: listening on tcp/$Port"
                return
            }
            Start-Sleep -Milliseconds 400
        }
        throw "windows_exporter not listening on tcp/$Port"
    }

    "stop" {
        $ids = @()
        if (Test-Path $PidFile) { $ids += Get-Content $PidFile }
        $ids += (Running | ForEach-Object { $_.Id })
        foreach ($id in ($ids | Sort-Object -Unique)) {
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        }
        Remove-Item $PidFile -ErrorAction SilentlyContinue
        Write-Output "stopped"
    }

    "status" {
        $l = Listener $Port
        $r = Running
        if ($l -and $r) { Write-Output "ok: windows_exporter pid=$($r.Id) listening tcp/$Port" }
        elseif ($r) { Write-Output "warn: running pid=$($r.Id) but not listening" }
        else { Write-Output "down: windows_exporter not running" }
    }

    "scrape" {
        $resp = Invoke-WebRequest -Uri "http://localhost:$Port/metrics" -UseBasicParsing -TimeoutSec 20
        Write-Output $resp.Content
    }
}
