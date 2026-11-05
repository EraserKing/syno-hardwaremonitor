#!/bin/sh
# HardwareMonitor probe. Read-only and model-independent.
# Does not write sysfs, does not open /dev/synobios, does not call FanSpeed set.
#
# Run as a normal SSH user, not root. Root hides permission problems the
# package user will hit. File modes are printed so a group-readable file
# still shows up as not-world-read.
set -u

LC_ALL=C
export LC_ALL
PATH="/usr/syno/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export PATH

DENIED=0
WORLD_OK=0
NOT_WORLD=0

section() {
    echo
    echo "===== $1 ====="
}

warn() {
    echo "WARN: $*"
}

# 8th character of an ls -l mode is other-read: -rw-r--r--
other_read() {
    case $1 in
        ???????r*) return 0 ;;
        *) return 1 ;;
    esac
}

note_file() {
    _f=$1
    _mode=$(ls -lL "$_f" 2>/dev/null | awk '{print $1; exit}')
    if [ -z "$_mode" ]; then
        echo "MISSING $_f"
        return 1
    fi
    if other_read "$_mode"; then
        WORLD_OK=$((WORLD_OK + 1))
        echo "MODE world-read $_mode $_f"
    else
        NOT_WORLD=$((NOT_WORLD + 1))
        echo "MODE not-world-read $_mode $_f"
    fi
    if [ ! -r "$_f" ]; then
        DENIED=$((DENIED + 1))
        echo "DENIED $_f"
        return 1
    fi
    return 0
}

dump_text() {
    _f=$1
    _max=${2:-200}
    if [ ! -e "$_f" ] && [ ! -L "$_f" ]; then
        echo "MISSING $_f"
        return
    fi
    if [ -d "$_f" ]; then
        echo "DIR $_f"
        ls -l "$_f" 2>&1
        return
    fi
    note_file "$_f" || return
    echo "-- $_f --"
    awk -v max="$_max" 'NR <= max { print } NR == max { exit }' "$_f" 2>/dev/null
    echo
}

kv() {
    _file=$1
    _key=$2
    if [ -x /usr/syno/bin/synogetkeyvalue ]; then
        /usr/syno/bin/synogetkeyvalue "$_file" "$_key" 2>/dev/null
        return
    fi
    if [ -r "$_file" ]; then
        awk -F= -v k="$_key" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$_file"
    fi
}

one_line() {
    _f=$1
    if [ -r "$_f" ]; then
        awk 'NR == 1 { print; exit }' "$_f" 2>/dev/null
    fi
}

section "how to read this"
echo "read_only=yes"
echo "uid=$(id -u) user=$(id -un) groups=$(id -Gn 2>/dev/null)"
if [ "$(id -u)" -eq 0 ]; then
    warn "running as root. This overstates what the package can read. Re-run as a normal user."
fi
echo "Package user will be sc-hardwaremonitor: not root, not in administrators."
echo "not-world-read means the package cannot use that file."

section "identity"
echo "hostname=$(hostname 2>/dev/null)"
echo "uname=$(uname -srm 2>/dev/null)"
if [ -r /proc/sys/kernel/syno_hw_version ]; then
    echo "syno_hw_version=$(one_line /proc/sys/kernel/syno_hw_version)"
else
    echo "syno_hw_version=MISSING"
fi
echo "unique=$(kv /etc.defaults/synoinfo.conf unique)"
echo "upnpmodelname=$(kv /etc.defaults/synoinfo.conf upnpmodelname)"
for _k in majorversion minorversion productversion buildnumber smallfixnumber buildphase; do
    echo "$_k=$(kv /etc.defaults/VERSION "$_k")"
done
echo "cpu_line=$(awk -F: '/^(model name|Processor|Hardware|cpu model|CPU implementer)/ { gsub(/^ /, "", $2); print $2; exit }' /proc/cpuinfo 2>/dev/null)"
echo "processors=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
echo "synogetkeyvalue=$(command -v synogetkeyvalue 2>/dev/null || echo missing)"
echo "synowebapi=$(command -v synowebapi 2>/dev/null || echo missing)"
echo "sensors=$(command -v sensors 2>/dev/null || echo missing)"

section "kernel syno names"
# Names only. Do not read unknown syno proc files; some are control nodes.
ls -1 /proc/sys/kernel/syno* 2>/dev/null || echo "none"
echo "-- platform devices matching temp/fan/hwmon --"
ls -d /sys/bus/platform/devices/*temp* /sys/bus/platform/devices/*fan* /sys/bus/platform/devices/*hwmon* 2>/dev/null || echo "none"

section "run hwmon"
for _dir in /run/hwmon /tmp/hwmon /var/run/hwmon; do
    if [ -d "$_dir" ]; then
        echo "DIR $_dir"
        ls -l "$_dir" 2>&1
        for _f in "$_dir"/*; do
            [ -e "$_f" ] || continue
            dump_text "$_f" 200
        done
    else
        echo "MISSING $_dir"
    fi
done

section "class hwmon"
_found=0
for _d in /sys/class/hwmon/hwmon*; do
    [ -d "$_d" ] || continue
    _found=1
    echo
    echo "## $_d"
    for _f in "$_d"/* "$_d"/device/*; do
        [ -f "$_f" ] || continue
        _base=$(basename "$_f")
        case $_base in
            name|uevent|*_label|*_input|*_average|*_max|*_crit|*_min|*_cap|*_enable|*_mode|fan[0-9]*|pwm[0-9]*|temp[0-9]*|in[0-9]*|power[0-9]*|curr[0-9]*|*intrusion*)
                dump_text "$_f" 4
                ;;
        esac
    done
done
if [ "$_found" -eq 0 ]; then
    echo "no /sys/class/hwmon/hwmon*"
fi

section "thermal zones"
_found=0
for _d in /sys/class/thermal/thermal_zone*; do
    [ -d "$_d" ] || continue
    _found=1
    echo
    echo "## $_d"
    dump_text "$_d/type" 2
    dump_text "$_d/temp" 2
done
if [ "$_found" -eq 0 ]; then
    echo "no thermal_zone"
fi

section "cpufreq"
if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver ]; then
    echo "scaling_driver=$(one_line /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)"
    note_file /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
else
    echo "scaling_driver=MISSING"
fi
_n=0
for _c in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -d "$_c" ] || continue
    _base=$(basename "$_c")
    case $_base in
        cpufreq|cpuidle|hotplug|isolated|kernel_max|modalias|nohz_full|offline|online|possible|present|power|smt|uevent|vulnerabilities)
            continue
            ;;
    esac
    if [ ! -d "$_c/cpufreq" ]; then
        echo "$_base cpufreq=MISSING"
        continue
    fi
    _n=$((_n + 1))
    echo "$_base cur_khz=$(one_line "$_c/cpufreq/scaling_cur_freq") min_khz=$(one_line "$_c/cpufreq/scaling_min_freq") max_khz=$(one_line "$_c/cpufreq/scaling_max_freq") governor=$(one_line "$_c/cpufreq/scaling_governor")"
done
echo "cpufreq_cpus=$_n"
echo "-- /proc/cpuinfo MHz, capped --"
grep -E '^(processor|cpu MHz|bogomips)' /proc/cpuinfo 2>/dev/null | head -n 128

section "power"
echo "-- powercap --"
_energy_list=""
if [ -d /sys/class/powercap ]; then
    ls -l /sys/class/powercap 2>&1
    for _f in $(find /sys/class/powercap -maxdepth 4 -type f \( -name name -o -name enabled -o -name energy_uj -o -name max_energy_range_uj -o -name constraint_0_power_limit_uw \) 2>/dev/null); do
        dump_text "$_f" 2
        case $_f in
            */energy_uj)
                if [ -r "$_f" ]; then
                    _energy_list="$_energy_list $_f"
                fi
                ;;
        esac
    done
    if [ -n "$_energy_list" ]; then
        echo "-- rapl 1s delta, read-only --"
        for _f in $_energy_list; do
            echo "t0 $_f $(one_line "$_f")"
        done
        sleep 1
        for _f in $_energy_list; do
            echo "t1 $_f $(one_line "$_f")"
        done
    else
        echo "no readable energy_uj"
    fi
else
    echo "MISSING /sys/class/powercap"
fi
echo "-- other power files, paths only --"
find /sys/class/hwmon /sys/class/power_supply -maxdepth 3 -type f \( -name 'power*_input' -o -name 'power*_average' -o -name 'curr*_input' \) 2>/dev/null | head -n 80

section "nic and disk temperature files"
echo "-- nic temperature files --"
for _f in $(find /sys/class/net -maxdepth 2 -type f -name temperature 2>/dev/null); do
    dump_text "$_f" 2
done
echo "-- disk temp-like files --"
for _f in $(find /sys/block /sys/class/scsi_disk /sys/class/scsi_device -maxdepth 6 -type f \( -name '*temp*' -o -name '*thermal*' \) 2>/dev/null | head -n 200); do
    dump_text "$_f" 2
done
if [ -d /run/synostorage ]; then
    echo "-- /run/synostorage temperature files --"
    for _f in $(find /run/synostorage -maxdepth 5 -type f -name '*temp*' 2>/dev/null | head -n 80); do
        dump_text "$_f" 2
    done
else
    echo "MISSING /run/synostorage"
fi

section "scemd fan policy"
for _f in /usr/syno/etc.defaults/scemd.xml /usr/syno/etc/scemd.xml; do
    if [ ! -e "$_f" ]; then
        echo "MISSING $_f"
        continue
    fi
    note_file "$_f" || continue
    echo "-- matching lines in $_f --"
    grep -E -i -n 'fan_config|fan_speed|pwm_duty|shutdown_temp|hibernation_speed|<temperature|</temperature>' "$_f" 2>/dev/null | head -n 220
done

section "fan api"
echo "FanSpeed set is not in this script."
if [ "$(id -u)" -eq 0 ] && [ -x /usr/syno/bin/synowebapi ]; then
    echo "-- synowebapi FanSpeed get, read-only --"
    /usr/syno/bin/synowebapi --exec api=SYNO.Core.Hardware.FanSpeed method=get version=1 2>&1
else
    echo "Not called here. Optional separate root command, still read-only:"
    echo "sudo /usr/syno/bin/synowebapi --exec api=SYNO.Core.Hardware.FanSpeed method=get version=1"
fi

section "summary"
echo "denied_files=$DENIED"
echo "world_read_files=$WORLD_OK"
echo "not_world_read_files=$NOT_WORLD"
echo "done"
