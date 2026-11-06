# HardwareMonitor

A hardware monitor for **Synology DSM 7**. It shows live fan RPM/PWM, CPU and
board temperatures, per-core clocks and governors, voltage rails, disk
temperatures and package power — and can switch DSM's fan profile through
Synology's official `SYNO.Core.Hardware.FanSpeed` WebAPI. Administrators can
also change the CPU frequency governor; everyone else sees it read-only.

![HardwareMonitor icon](ui/images/icon_256.png)

Author: **EraserKing**

## Features

- Live sensor dashboard inside DSM (ExtJS app window).
- System **load** and **memory** gauges, scaled to 0–100%.
- CPU **package temperature** gauge with the maximum allowed temperature.
- One card per CPU core with temperature, current clock and its governor.
- CPU governor control: the list of governors is read from the kernel
  (`scaling_available_governors`), never hardcoded. Apply one governor to all
  cores, or tune individual cores.
- Voltage rails with nominal value, difference and difference percentage
  (`12 V`, `5 V`, `3.3 V`, …).
- Disk temperature gauges against the scemd shutdown threshold.
- Full sensor table with min/max, source, quality and notes.
- Fan mode selector: Quiet, Cool, Full and, where supported, Quiet stop.
- Adjustable refresh interval (1 s, 2 s, 5 s, 10 s, 30 s or off).

## Safety

Sensor collection is read-only. The package makes exactly one class of system
change, and only when an administrator asks for it:

- **CPU governor** — `ui/governor.cgi` validates the requested value against the
  governors the kernel currently reports, then runs `bin/gov-helper` once for
  each target core. The helper re-checks the value and writes only
  `.../cpufreq/scaling_governor`. No other sysfs file is written.
- Normal DSM users can open the governor dialog but the controls are disabled.
  Only members of DSM's administrators group (`gid 101`) can apply a change.
- Cross-origin POSTs are rejected, and the request must come from a logged-in
  DSM session.
- The helper is a small freestanding binary with no libc or dynamic-loader
  dependency. It accepts exactly `cpuN` and a governor name, rejects path
  traversal and shell metacharacters, and refuses any governor not listed by
  the kernel in `scaling_available_governors`.

What it still never does:

- never opens `/dev/synobios`;
- never writes fan/PWM registers directly;
- changes fan mode **only** through DSM's official
  `SYNO.Core.Hardware.FanSpeed` API;
- flags suspicious readings (zero pins, unscaled `SYSTIN`/`AUXTIN`, DSM vs chip
  mismatches) instead of presenting them as facts.

### Why the package does not run as root

DSM 7 refuses to install third-party packages that declare `run-as: root`
(`error 319`, "invalid package privilege content"). HardwareMonitor therefore
runs as its own `sc-hardwaremonitor` service account.

`spk/conf/privilege` uses DSM's `tool` section to install `bin/gov-helper` as
`root:<package-group>` with mode `6550`. Only the package's own group can
execute it, and it can do exactly one thing: validate and write
`scaling_governor` for a named core. The collector, the CGI and the UI all run
unprivileged.

This also means the collector can only read sensor files that are readable by
the service account. `probe.sh` reports what the current user can read and what
the installed package privilege is set to.

## Architecture

| Path | Purpose |
|---|---|
| `collect.sh` | Read-only sensor collector. Reads sysfs/proc/Synology files and writes a JSON snapshot. In `--daemon` mode it refreshes the snapshot and keeps a state file for min/max and RAPL energy deltas. |
| `ui/governor.cgi` | Admin-gated governor endpoint. GET returns driver, dynamic governor list and per-core state; POST validates a change and runs the setuid helper. It never writes sysfs itself. |
| `helper/gov-helper.c` | Narrow setuid-root helper. Accepts `cpuN` plus one governor, verifies it against `scaling_available_governors`, and writes `scaling_governor`. Freestanding: no libc. |
| `spk/conf/privilege` | Runs the package as its service account and installs `bin/gov-helper` as `root:<package-group>` mode `6550`. |
| `probe.sh` | Read-only diagnostic. Run it on the NAS as a normal user to see file modes, readable sensors and fan policy. |
| `test.sh` | Fixture-based regression test. Does not touch real hardware. |
| `build.sh` | Builds the unsigned DSM 7 `.spk` into `dist/`, including the helper. |
| `spk/` | DSM package metadata and lifecycle scripts. |
| `ui/` | DSM ExtJS UI, stylesheet, snapshot/governor CGI and icons. |

### Data sources

- `/sys/class/hwmon` — chip sensors (coretemp, k10temp, nct67xx, …)
- `/run/hwmon/*.json` — scemd summaries
- `/sys/class/thermal` — thermal zones
- `/sys/devices/system/cpu/*/cpufreq` — clocks, current governor and the
  kernel-reported `scaling_available_governors`
- `/sys/class/powercap` — RAPL energy counters
- `/run/synostorage/disks/*/temperature` — disk temperatures
- `/proc/{loadavg,meminfo,uptime,cpuinfo}` — system state
- `/sys/class/net` — NIC link speed
- `/usr/syno/etc/scemd.xml` — shutdown temperature thresholds

## Requirements

- DSM 7.0 or newer.
- To build: `gcc` (or `CC`), `python3`, `tar`, `gzip`, POSIX `sh`.
- To test: `python3` and a C compiler for the helper tests.
- The helper supports **x86_64** and **aarch64**. Build on the same
  architecture as the NAS, or point `CC` at a cross compiler.

## Build

```sh
./build.sh
```

The output is `dist/hardwaremonitor-<version>.spk`.

The build compiles `helper/gov-helper.c` with the host C compiler (`CC` can
override it) and packages it as `bin/gov-helper`. The helper is statically
linked and freestanding, so it has no runtime libc version requirement. It
currently supports x86_64 and aarch64; the build fails on any other
architecture. `spk/INFO` declares the package `noarch`, so build on the same
architecture as the NAS (or use a cross compiler) — otherwise the package
installs but governor changes fail gracefully.

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

The test builds a temporary fake NAS root (CPU, cpufreq governors, hwmon, disks,
scemd limits, load/memory) and asserts the generated JSON, including the
`governor` object. It also compiles the helper in test mode and exercises
`ui/governor.cgi` against a fixture: dynamic governor discovery, the
administrator gate, apply-all, per-core changes, invalid values, cross-origin
rejection, path traversal and shell injection. It never reads or writes the
live machine.

## Probe

```sh
scp probe.sh nas:/tmp/
ssh nas sh /tmp/probe.sh
```

Run it as a normal SSH user, **not root**. It is read-only and shows the file
modes and sensors available to your account, plus the package's configured
privilege, so you can tell what the collector will see.

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
- Governor changes depend on the cpufreq driver. The dialog only offers values
  from `scaling_available_governors`; if the driver refuses a write, the CGI
  reports which cores were rejected and leaves the rest untouched.
- The packaged helper is built for the build host's architecture. If it cannot
  run on the NAS, the governor dialog still works read-only and reports that the
  helper is unavailable.
- Cores may legitimately run different governors; the per-core cards show the
  live value, and "Apply to all cores" overwrites all of them.
