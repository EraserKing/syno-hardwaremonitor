# HardwareMonitor

A read-only hardware monitor for **Synology DSM 7**. It shows live fan RPM/PWM,
CPU and board temperatures, per-core clocks, voltage rails, disk temperatures and
package power — and can switch DSM's fan profile through Synology's official
`SYNO.Core.Hardware.FanSpeed` WebAPI.

![HardwareMonitor icon](ui/images/icon_256.png)

Author: **EraserKing**

## Features

- Live sensor dashboard inside DSM (ExtJS app window).
- System **load** and **memory** gauges, scaled to 0–100%.
- CPU **package temperature** gauge with the maximum allowed temperature.
- One card per CPU core with temperature and current clock.
- Voltage rails with nominal value, difference and difference percentage
  (`12 V`, `5 V`, `3.3 V`, …).
- Disk temperature gauges against the scemd shutdown threshold.
- Full sensor table with min/max, source, quality and notes.
- Fan mode selector: Quiet, Cool, Full and, where supported, Quiet stop.
- Adjustable refresh interval (1 s, 2 s, 5 s, 10 s, 30 s or off).

## Safety

This package is read-only by design:

- never writes sysfs;
- never opens `/dev/synobios`;
- never writes fan/PWM registers directly;
- changes fan mode **only** through DSM's official
  `SYNO.Core.Hardware.FanSpeed` API;
- flags suspicious readings (zero pins, unscaled `SYSTIN`/`AUXTIN`, DSM vs chip
  mismatches) instead of presenting them as facts.

The UI is served by DSM from `/webman/3rdparty/hardwaremonitor/`. The collector runs
as the unprivileged `package` user, so some sensors may be unreadable depending
on model and DSM build. `probe.sh` reports exactly what that user can read.

## Architecture

| Path | Purpose |
|---|---|
| `collect.sh` | Main collector. Reads sysfs/proc/Synology files and writes a JSON snapshot. Supports `--daemon` and keeps a state file for min/max and RAPL energy deltas. |
| `probe.sh` | Read-only diagnostic. Run it on the NAS as a normal user to see file modes, readable sensors and fan policy. |
| `test.sh` | Fixture-based regression test. Does not touch real hardware. |
| `build.sh` | Builds the unsigned DSM 7 `.spk` into `dist/`. |
| `spk/` | DSM package metadata and lifecycle scripts. |
| `ui/` | DSM ExtJS UI, stylesheet, snapshot CGI and icons. |

### Data sources

- `/sys/class/hwmon` — chip sensors (coretemp, k10temp, nct67xx, …)
- `/run/hwmon/*.json` — scemd summaries
- `/sys/class/thermal` — thermal zones
- `/sys/devices/system/cpu/*/cpufreq` — clocks and governor
- `/sys/class/powercap` — RAPL energy counters
- `/run/synostorage/disks/*/temperature` — disk temperatures
- `/proc/{loadavg,meminfo,uptime,cpuinfo}` — system state
- `/sys/class/net` — NIC link speed
- `/usr/syno/etc/scemd.xml` — shutdown temperature thresholds

## Requirements

- DSM 7.0 or newer (`noarch` package).
- To build: `python3`, `tar`, `gzip`, POSIX `sh`.
- To test: `python3`.

## Build

```sh
./build.sh
```

The output is `dist/hardwaremonitor-<version>.spk`.

`spk/INFO` is the version source. Each build automatically increments the build
number, writes it back to `spk/INFO`, and derives the versioned UI module name
and CSS cache key from it. To force a version:

```sh
VERSION=0.1.0-0020 ./build.sh
```

The UI is packaged as `ui/hardwaremonitor-ui-<build>.js`, `ui/config` is rewritten to
point at it, and the stylesheet URL becomes `style.css?v=<build>`, so upgrades
bypass DSM/browser caches.

## Install

In DSM: **Package Center → Manual Install**, then choose the `.spk` from
`dist/`. DSM will warn that the package is from an unknown publisher.

Or from an SSH session:

```sh
sudo synopkg install dist/hardwaremonitor-<version>.spk
sudo synopkg start hardwaremonitor
```

Open **HardwareMonitor** from the DSM main menu. It is a desktop window, not a browser
tab.

## Test

```sh
./test.sh
```

The test builds a temporary fake NAS root (CPU, hwmon, disks, scemd limits,
load/memory) and asserts the generated JSON. It never reads or writes the live
machine.

## Probe

```sh
scp probe.sh nas:/tmp/
ssh nas sh /tmp/probe.sh
```

Run it as a normal SSH user, **not root**. Root hides the permission problems
the package user will hit.

## Notes and limitations

- The load gauge is the 1-minute load average divided by the CPU count
  (100% = all cores busy). It is not `/proc/stat` utilisation.
- Core clock mapping is best effort: `Core N` is matched to `cpuN.mhz`.
  SMT systems may show one thread's clock.
- Disk gauges need `shutdown_temp` entries in `scemd.xml`; otherwise a plain
  temperature card is shown.
- Fan mode availability depends on the model and DSM's `FanSpeed` API.
- RAPL package power appears on the second sample, after an energy delta is
  available.
