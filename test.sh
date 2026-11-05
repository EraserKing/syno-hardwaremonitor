#!/bin/sh
# Fixture from the NAS probe. Does not touch the live machine.
set -eu
cd "$(dirname "$0")"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

mkdir -p \
    "$root/proc/sys/kernel" \
    "$root/etc.defaults" \
    "$root/run/hwmon" \
    "$root/run/synostorage/disks/sata1" \
    "$root/run/synostorage/disks/sata2" \
    "$root/sys/class/hwmon/hwmon0" \
    "$root/sys/class/hwmon/hwmon1" \
    "$root/sys/class/hwmon/hwmon2" \
    "$root/sys/class/thermal/thermal_zone0" \
    "$root/sys/devices/system/cpu/cpu0/cpufreq" \
    "$root/sys/devices/system/cpu/cpu1/cpufreq" \
    "$root/usr/syno/etc.defaults"

printf '%s\n' SA6400 > "$root/proc/sys/kernel/syno_hw_version"
printf '%s\n' 'unique="synology_epyc7002_sa6400"' > "$root/etc.defaults/synoinfo.conf"
printf '%s\n' 'upnpmodelname="SA6400"' >> "$root/etc.defaults/synoinfo.conf"
printf '%s\n' 'serial="SHOULD_NOT_APPEAR"' >> "$root/etc.defaults/synoinfo.conf"
cat > "$root/etc.defaults/VERSION" <<'EOF'
majorversion="7"
productversion="7.4.1"
buildnumber="90080"
smallfixnumber="1"
EOF
cat > "$root/proc/cpuinfo" <<'EOF'
processor	: 0
model name	: Intel(R) Core(TM) i3-8100 CPU @ 3.60GHz
cpu MHz		: 3599.988
EOF
printf '%s\n' '0.50 0.40 0.30 1/123 456' > "$root/proc/loadavg"
cat > "$root/proc/meminfo" <<'EOF'
MemTotal:        8123456 kB
MemAvailable:    4061728 kB
EOF
printf '%s\n' '{ "CPU_Temperature": { "CPU_0": "65", "CPU_1": "65" } }' > "$root/run/hwmon/cpu_temperature.json"
printf '%s\n' '{ "System_Fan_Speed_RPM": { "fan1_rpm": "985", "fan2_rpm": "1000" } }' > "$root/run/hwmon/sys_fan_speed_rpm.json"
printf '%s\n' '{ "System_Thermal_Sensor": { "Remote1": "35", "Local": "32" } }' > "$root/run/hwmon/sys_thermal_sensor.json"
printf '%s\n' '{ "System_Voltage_Sensor": { "VCC": "12026", "V33": "3340", "V5": "4801", "V12": "12212" } }' > "$root/run/hwmon/sys_voltage_sensor.json"
printf '%s\n' '{ "PSU_1_Status": { "power_out": "", "status": "" } }' > "$root/run/hwmon/psu_status.json"
cat > "$root/usr/syno/etc.defaults/scemd.xml" <<'EOF'
<fan_config>
  <disk_temperature name="disk" shutdown_temp="60"/>
  <disk_temperature name="m2" shutdown_temp="70"/>
  <cpu_temperature name="cpu" shutdown_temp="95"/>
</fan_config>
EOF

printf '%s\n' coretemp > "$root/sys/class/hwmon/hwmon0/name"
printf '%s\n' 49000 > "$root/sys/class/hwmon/hwmon0/temp1_input"
printf '%s\n' 'Package id 0' > "$root/sys/class/hwmon/hwmon0/temp1_label"
printf '%s\n' 80000 > "$root/sys/class/hwmon/hwmon0/temp1_max"
printf '%s\n' 100000 > "$root/sys/class/hwmon/hwmon0/temp1_crit"
printf '%s\n' 48000 > "$root/sys/class/hwmon/hwmon0/temp2_input"
printf '%s\n' 'Core 0' > "$root/sys/class/hwmon/hwmon0/temp2_label"

printf '%s\n' nct6793 > "$root/sys/class/hwmon/hwmon1/name"
printf '%s\n' 1311 > "$root/sys/class/hwmon/hwmon1/fan1_input"
printf '%s\n' 3146 > "$root/sys/class/hwmon/hwmon1/fan2_input"
printf '%s\n' 0 > "$root/sys/class/hwmon/hwmon1/fan3_input"
printf '%s\n' 255 > "$root/sys/class/hwmon/hwmon1/pwm1"
printf '%s\n' 0 > "$root/sys/class/hwmon/hwmon1/pwm1_enable"
printf '%s\n' 1 > "$root/sys/class/hwmon/hwmon1/pwm1_mode"
printf '%s\n' 77 > "$root/sys/class/hwmon/hwmon1/pwm3"
printf '%s\n' 1 > "$root/sys/class/hwmon/hwmon1/pwm3_enable"
printf '%s\n' 1 > "$root/sys/class/hwmon/hwmon1/pwm3_mode"
printf '%s\n' 124 > "$root/sys/class/hwmon/hwmon1/pwm5"
printf '%s\n' 5 > "$root/sys/class/hwmon/hwmon1/pwm5_enable"
printf '%s\n' 114000 > "$root/sys/class/hwmon/hwmon1/temp1_input"
printf '%s\n' SYSTIN > "$root/sys/class/hwmon/hwmon1/temp1_label"
printf '%s\n' 42000 > "$root/sys/class/hwmon/hwmon1/temp2_input"
printf '%s\n' CPUTIN > "$root/sys/class/hwmon/hwmon1/temp2_label"
printf '%s\n' 47500 > "$root/sys/class/hwmon/hwmon1/temp7_input"
printf '%s\n' 'PECI Agent 0' > "$root/sys/class/hwmon/hwmon1/temp7_label"
printf '%s\n' 400 > "$root/sys/class/hwmon/hwmon1/in0_input"
printf '%s\n' 3408 > "$root/sys/class/hwmon/hwmon1/in2_input"
printf '%s\n' 136 > "$root/sys/class/hwmon/hwmon1/in5_input"

printf '%s\n' iwlwifi_1 > "$root/sys/class/hwmon/hwmon2/name"
printf '%s\n' 34000 > "$root/sys/class/hwmon/hwmon2/temp1_input"
printf '%s\n' iwlwifi_1 > "$root/sys/class/thermal/thermal_zone0/type"
printf '%s\n' 34000 > "$root/sys/class/thermal/thermal_zone0/temp"

printf '%s\n' acpi-cpufreq > "$root/sys/devices/system/cpu/cpu0/cpufreq/scaling_driver"
printf '%s\n' performance > "$root/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
printf '%s\n' 3600061 > "$root/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
printf '%s\n' 800000 > "$root/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq"
printf '%s\n' 3600000 > "$root/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"
printf '%s\n' 3599968 > "$root/sys/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq"
printf '%s\n' 800000 > "$root/sys/devices/system/cpu/cpu1/cpufreq/scaling_min_freq"
printf '%s\n' 3600000 > "$root/sys/devices/system/cpu/cpu1/cpufreq/scaling_max_freq"
printf '%s\n' 46 > "$root/run/synostorage/disks/sata1/temperature"
printf '%s\n' ST4000 > "$root/run/synostorage/disks/sata1/model"
printf '%s\n' 49 > "$root/run/synostorage/disks/sata2/temperature"

state=$(mktemp)
out=$(mktemp)
HARDWAREMONITOR_ROOT="$root" HARDWAREMONITOR_STATE="$state" HARDWAREMONITOR_SNAPSHOT="$out" HARDWAREMONITOR_HOSTNAME=NAS \
    sh ./collect.sh
python3 - "$out" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["profile_mismatch"] is True, data["profile_mismatch"]
assert data["host"]["model"] == "SA6400"
assert data["host"]["dsm"] == "7.4.1-90080-1"
assert "Intel" in data["host"]["cpu"]
assert "SHOULD_NOT_APPEAR" not in json.dumps(data)
assert data["host"]["cpus"] == 1
sensors = {s["id"]: s for g in data["groups"] for s in g["sensors"]}
assert sensors["sys.load"]["pct"] == 50
assert sensors["sys.mem"]["pct"] == 50
assert sensors["coretemp.temp1"]["value"] == 49.0
assert sensors["coretemp.temp1"]["limit_crit"] == 100
assert sensors["dsm.CPU_0"]["value"] == 65
assert sensors["nct6793.fan1"]["value"] == 1311
assert sensors["nct6793.fan2"]["value"] == 3146
assert sensors["nct6793.fan3"]["quality"] == "stopped"
assert sensors["dsm.fan1"]["value"] == 985
assert sensors["nct6793.pwm1"]["value"] == 100.0
assert "full speed" in sensors["nct6793.pwm1"]["note"]
assert sensors["nct6793.pwm3"]["value"] == 30.2
assert "manual" in sensors["nct6793.pwm3"]["note"]
assert "Smart Fan IV" in sensors["nct6793.pwm5"]["note"]
assert sensors["nct6793.temp1"]["quality"] == "suspect"
assert sensors["nct6793.temp2"]["quality"] == "ok"
assert sensors["nct6793.temp2"]["value"] == 42.0
assert "nct6793.in5" not in sensors
assert sensors["nct6793.in2"]["value"] == 3.408
assert sensors["dsm.volt.VCC"]["value"] == 12.026
assert sensors["cpu0.mhz"]["value"] == 3600
assert sensors["cpu.governor"]["value"] == "performance"
assert sensors["cpu.package_power"]["quality"] == "not_exposed"
assert sensors["cpu.package_power"]["value"] is None
assert sensors["disk.sata1"]["value"] == 46
assert "ST4000" in sensors["disk.sata1"]["label"]
assert sensors["limit.disk"]["value"] == 60
assert sensors["limit.m2"]["value"] == 70
assert sensors["limit.cpu"]["value"] == 95
assert sensors["iwlwifi_1.temp1"]["value"] == 34.0
assert not any(s["id"].startswith("zone.") for g in data["groups"] for s in g["sensors"])
print("fixture ok", len(sensors), "sensors")
PY

# min/max across two samples
python3 - <<PY
from pathlib import Path
p = Path("$root/sys/class/hwmon/hwmon0/temp1_input")
p.write_text("51000\\n")
PY
HARDWAREMONITOR_ROOT="$root" HARDWAREMONITOR_STATE="$state" HARDWAREMONITOR_SNAPSHOT="$out" HARDWAREMONITOR_HOSTNAME=NAS \
    sh ./collect.sh
python3 - "$out" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
sensors = {s["id"]: s for g in data["groups"] for s in g["sensors"]}
assert sensors["coretemp.temp1"]["value"] == 51.0
assert sensors["coretemp.temp1"]["min"] == 49.0
assert sensors["coretemp.temp1"]["max"] == 51.0
print("minmax ok")
PY
echo TEST_OK
