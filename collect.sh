#!/bin/sh
# Read-only sensor snapshot. Model-independent.
# Never writes sysfs, never opens /dev/synobios, never sets fan mode.
#
# HARDWAREMONITOR_ROOT  prefix for a fixture (default: real root)
# HARDWAREMONITOR_STATE min/max and RAPL sample file
# HARDWAREMONITOR_SNAPSHOT write JSON here (default: stdout)
# HARDWAREMONITOR_HOSTNAME override hostname
set -u

if [ "${1:-}" = "--daemon" ]; then
    interval=${HARDWAREMONITOR_INTERVAL:-1}
    out=${HARDWAREMONITOR_SNAPSHOT:?set HARDWAREMONITOR_SNAPSHOT}
    st=${HARDWAREMONITOR_STATE:-$out.state}
    while true; do
        HARDWAREMONITOR_SNAPSHOT="$out" HARDWAREMONITOR_STATE="$st" "$0" || true
        sleep "$interval"
    done
fi

root=${HARDWAREMONITOR_ROOT:-}
state=${HARDWAREMONITOR_STATE:-}
snapshot=${HARDWAREMONITOR_SNAPSHOT:-}

p() {
    printf '%s%s' "$root" "$1"
}

read1() {
    _f=$1
    if [ -r "$_f" ]; then
        awk 'NR == 1 { gsub(/\r/, ""); print; exit }' "$_f"
    fi
}

clean() {
    printf '%s' "$1" | tr '\t\r\n' '   '
}

kv() {
    _file=$1
    _key=$2
    if [ -r "$_file" ]; then
        awk -F= -v k="$_key" '
            $1 == k {
                v = substr($0, index($0, "=") + 1)
                gsub(/^"/, "", v)
                gsub(/"$/, "", v)
                print v
                exit
            }
        ' "$_file"
    fi
}

scale_div() {
    # $1 raw integer, $2 divisor, $3 printf format
    awk -v n="$1" -v d="$2" -v fmt="$3" 'BEGIN {
        if (n == "" || n !~ /^-?[0-9]+$/) exit 1
        printf(fmt, n / d)
    }'
}

tsv=$(mktemp "${TMPDIR:-/tmp}/hardwaremonitor.XXXXXX")
trap 'rm -f "$tsv"' EXIT INT TERM

add() {
    # S id group label value unit source quality note limit_max limit_crit pct
    printf 'S\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10:-}" "${11:-}" >> "$tsv"
}

add_temp_file() {
    _id=$1
    _group=$2
    _label=$3
    _raw=$4
    _source=$5
    _maxraw=$6
    _critraw=$7
    _val=$(scale_div "$_raw" 1000 "%.1f" 2>/dev/null || true)
    [ -n "$_val" ] || return 0
    _quality=ok
    _note=
    # 0 means the pin is not connected on most hwmon chips.
    if [ "$_val" = "0.0" ] || [ "$_val" = "0" ]; then
        _quality=unavailable
        _note="reading is zero"
    fi
    _limmax=
    _limcrit=
    if [ -n "$_maxraw" ]; then
        _limmax=$(scale_div "$_maxraw" 1000 "%.0f" 2>/dev/null || true)
    fi
    if [ -n "$_critraw" ]; then
        _limcrit=$(scale_div "$_critraw" 1000 "%.0f" 2>/dev/null || true)
    fi
    # A board sensor far above a sane CPU package is usually an unscaled pin.
    case $_label in
        SYSTIN|AUXTIN*|AUXTIN[0-9]*)
            if awk -v v="$_val" 'BEGIN { exit !(v+0 >= 95) }'; then
                _quality=suspect
                _note="far above a normal CPU package; pin may be unscaled or open"
            fi
            ;;
    esac
    add "$_id" "$_group" "$_label" "$_val" "C" "$_source" "$_quality" "$_note" "$_limmax" "$_limcrit"
}

walk_hwmon() {
    _d=$1
    [ -d "$_d" ] || return 0
    _name=$(read1 "$_d/name")
    [ -n "$_name" ] || _name=$(basename "$_d")
    _name=$(clean "$_name")

    _tempgroup=board
    case $_name in
        coretemp|k10temp|zenpower|cpu_thermal|k8temp|fam15h_power)
            _tempgroup=cpu
            ;;
        *wifi*|*iwl*|*nic*)
            _tempgroup=nic
            ;;
    esac

    _i=1
    while [ "$_i" -le 16 ]; do
        _in="$_d/temp${_i}_input"
        if [ -r "$_in" ]; then
            _label=$(read1 "$_d/temp${_i}_label")
            [ -n "$_label" ] || _label="temp$_i"
            _label=$(clean "$_label")
            _id=$(printf '%s.temp%s' "$_name" "$_i" | tr ' /' '__')
            add_temp_file "$_id" "$_tempgroup" "$_label" "$(read1 "$_in")" "$_name" \
                "$(read1 "$_d/temp${_i}_max")" "$(read1 "$_d/temp${_i}_crit")"
        fi
        _i=$((_i + 1))
    done

    _i=1
    while [ "$_i" -le 8 ]; do
        _in="$_d/fan${_i}_input"
        if [ -r "$_in" ]; then
            _rpm=$(read1 "$_in")
            _quality=ok
            _note=
            case $_rpm in
                ""|*[!0-9-]*) _rpm=; _quality=unavailable; _note="unreadable" ;;
                0) _quality=stopped; _note="no tach, or fan is stopped" ;;
            esac
            _id=$(printf '%s.fan%s' "$_name" "$_i")
            add "$_id" "fans" "$_name fan$_i" "$_rpm" "RPM" "$_name" "$_quality" "$_note" "" ""
        fi
        _pwm="$_d/pwm${_i}"
        if [ -r "$_pwm" ]; then
            _raw=$(read1 "$_pwm")
            _pct=$(scale_div "$_raw" 2.55 "%.1f" 2>/dev/null || true)
            _en=$(read1 "$_d/pwm${_i}_enable")
            _mode=$(read1 "$_d/pwm${_i}_mode")
            _en_text=
            case $_en in
                0) _en_text="control disabled, chip forces full speed" ;;
                1) _en_text="manual" ;;
                2) _en_text="thermal cruise" ;;
                3) _en_text="speed cruise" ;;
                4) _en_text="Smart Fan III" ;;
                5) _en_text="Smart Fan IV" ;;
                "") _en_text="enable unknown" ;;
                *) _en_text="enable $_en" ;;
            esac
            _drv=
            case $_mode in
                0) _drv=", DC" ;;
                1) _drv=", PWM" ;;
            esac
            _id=$(printf '%s.pwm%s' "$_name" "$_i")
            add "$_id" "fans" "$_name pwm$_i" "$_pct" "%" "$_name" "ok" "$_en_text$_drv, raw ${_raw:-?}/255" "" ""
        fi
        _i=$((_i + 1))
    done

    _i=0
    while [ "$_i" -le 16 ]; do
        _in="$_d/in${_i}_input"
        if [ -r "$_in" ]; then
            _raw=$(read1 "$_in")
            _volts=$(scale_div "$_raw" 1000 "%.3f" 2>/dev/null || true)
            if awk -v v="${_volts:-0}" 'BEGIN { exit !(v+0 >= 0.3) }'; then
                _label=$(read1 "$_d/in${_i}_label")
                [ -n "$_label" ] || _label="$_name in$_i"
                _label=$(clean "$_label")
                _id=$(printf '%s.in%s' "$_name" "$_i")
                add "$_id" "voltage" "$_label" "$_volts" "V" "$_name" "ok" "hwmon millivolts, already scaled by the driver" "" ""
            fi
        fi
        _pow="$_d/power${_i}_input"
        if [ ! -r "$_pow" ]; then
            _pow="$_d/power${_i}_average"
        fi
        if [ -r "$_pow" ]; then
            _raw=$(read1 "$_pow")
            _w=$(scale_div "$_raw" 1000000 "%.2f" 2>/dev/null || true)
            if [ -n "$_w" ]; then
                _label=$(read1 "$_d/power${_i}_label")
                [ -n "$_label" ] || _label="$_name power$_i"
                add "$(printf '%s.power%s' "$_name" "$_i")" "cpu" "$_label" "$_w" "W" "$_name" "ok" "" "" ""
            fi
        fi
        _i=$((_i + 1))
    done
}

walk_run_hwmon() {
    _dir=$(p /run/hwmon)
    if [ ! -d "$_dir" ]; then
        _dir=$(p /var/run/hwmon)
    fi
    [ -d "$_dir" ] || return 0
    for _f in "$_dir"/*.json; do
        [ -f "$_f" ] || continue
        # One object per file. Values are strings. Skip empty stubs.
        _parsed=$(mktemp "${TMPDIR:-/tmp}/hardwaremonitor.parse.XXXXXX")
        awk '
            function emit(id, group, label, value, unit, note) {
                gsub(/\t/, " ", id)
                gsub(/\t/, " ", label)
                printf "S\t%s\t%s\t%s\t%s\t%s\t/run/hwmon\tok\t%s\t\t\n", id, group, label, value, unit, note
            }
            {
                s = $0
                while (match(s, /"[^"]+" *: *"[^"]*"/)) {
                    pair = substr(s, RSTART, RLENGTH)
                    s = substr(s, RSTART + RLENGTH)
                    split(pair, q, "\"")
                    key = q[2]
                    val = q[4]
                    if (val == "") continue
                    if (key ~ /^CPU_/) {
                        emit("dsm." key, "cpu", "DSM " key, val, "C", "scemd summary, may not match coretemp")
                    } else if (key ~ /_rpm$/) {
                        n = key
                        sub(/_rpm$/, "", n)
                        sub(/^fan/, "", n)
                        emit("dsm.fan" n, "fans", "DSM " key, val, "RPM", "scemd summary")
                    } else if (key ~ /^(Remote|Local)/) {
                        emit("dsm.thermal." key, "board", "DSM " key, val, "C", "scemd thermal")
                    } else if (key ~ /^V/) {
                        printf "VOLT\t%s\t%s\n", key, val
                    } else if (key == "power_in" || key == "power_out") {
                        emit("dsm." key, "cpu", "DSM " key, val, "W", "PSU, not CPU package power")
                    }
                }
            }
        ' "$_f" > "$_parsed"
        while read -r _line; do
            case $_line in
                VOLT*)
                    _key=$(printf '%s' "$_line" | awk '{print $2}')
                    _mv=$(printf '%s' "$_line" | awk '{print $3}')
                    _v=$(scale_div "$_mv" 1000 "%.3f" 2>/dev/null || true)
                    [ -n "$_v" ] || continue
                    add "dsm.volt.$_key" "voltage" "DSM $_key" "$_v" "V" "/run/hwmon" "ok" "scemd voltage sensor" "" ""
                    ;;
                S*)
                    printf '%s\n' "$_line" >> "$tsv"
                    ;;
            esac
        done < "$_parsed"
        rm -f "$_parsed"
    done
}

walk_cpufreq() {
    _base=$(p /sys/devices/system/cpu)
    [ -d "$_base" ] || return 0
    _drv=$(read1 "$_base/cpu0/cpufreq/scaling_driver")
    [ -n "$_drv" ] || _drv=cpufreq
    _gov=$(read1 "$_base/cpu0/cpufreq/scaling_governor")
    if [ -n "$_gov" ]; then
        add "cpu.governor" "cpu" "Governor" "$_gov" "" "$_drv" "ok" "" "" ""
    fi
    for _c in "$_base"/cpu[0-9]*; do
        [ -d "$_c/cpufreq" ] || continue
        _n=$(basename "$_c")
        case $_n in
            cpu*[!0-9]*) continue ;;
        esac
        _cur=$(read1 "$_c/cpufreq/scaling_cur_freq")
        _mhz=$(scale_div "$_cur" 1000 "%.0f" 2>/dev/null || true)
        [ -n "$_mhz" ] || continue
        _min=$(read1 "$_c/cpufreq/scaling_min_freq")
        _max=$(read1 "$_c/cpufreq/scaling_max_freq")
        _minmhz=$(scale_div "${_min:-0}" 1000 "%.0f" 2>/dev/null || true)
        _maxmhz=$(scale_div "${_max:-0}" 1000 "%.0f" 2>/dev/null || true)
        _note=
        if [ -n "$_minmhz" ] && [ -n "$_maxmhz" ]; then
            _note="range ${_minmhz}-${_maxmhz} MHz"
        fi
        add "$_n.mhz" "cpu" "$_n clock" "$_mhz" "MHz" "$_drv" "ok" "$_note" "" ""
    done
}

walk_rapl() {
    _cap=$(p /sys/class/powercap)
    [ -d "$_cap" ] || return 0
    _found=0
    for _f in $(find "$_cap" -maxdepth 4 -type f -name energy_uj 2>/dev/null); do
        _found=1
        _zone=$(dirname "$_f")
        _zname=$(read1 "$_zone/name")
        [ -n "$_zname" ] || _zname=$(basename "$_zone")
        _uj=$(read1 "$_f")
        [ -n "$_uj" ] || continue
        # The awk stage turns two samples into watts. Marker is not a sensor yet.
        printf 'RAPL\t%s\t%s\t%s\n' "$_zname" "$_uj" "$_f" >> "$tsv"
    done
    if [ "$_found" -eq 0 ]; then
        return 0
    fi
}

walk_load() {
    _f=$(p /proc/loadavg)
    [ -r "$_f" ] || return 0
    set -- $(read1 "$_f")
    [ -n "${1:-}" ] || return 0
    # Load average as a percentage of the CPU count, so the UI can gauge it.
    _pct=$(awk -v l="$1" -v n="${host_cpus:-0}" 'BEGIN {
        if (n > 0) printf "%.0f", l * 100 / n
        else print 0
    }')
    add "sys.load" "system" "Load" "$1" "" "proc" "ok" "5m ${2:-?}  15m ${3:-?}" "" "" "$_pct"
}

walk_mem() {
    _f=$(p /proc/meminfo)
    [ -r "$_f" ] || return 0
    _total=$(awk '/^MemTotal:/ { print $2; exit }' "$_f")
    _avail=$(awk '/^MemAvailable:/ { print $2; exit }' "$_f")
    [ -n "$_total" ] || return 0
    if [ -z "$_avail" ]; then
        _avail=$(awk '/^MemFree:/ { print $2; exit }' "$_f")
    fi
    _used=$(awk -v t="$_total" -v a="${_avail:-0}" 'BEGIN { printf "%.1f", (t - a) / 1024 / 1024 }')
    _gib=$(awk -v t="$_total" 'BEGIN { printf "%.1f", t / 1024 / 1024 }')
    _pct=$(awk -v t="$_total" -v a="${_avail:-0}" 'BEGIN { if (t > 0) printf "%.0f", (t - a) * 100 / t; else print 0 }')
    add "sys.mem" "system" "Memory" "$_used" "GiB" "proc" "ok" "of ${_gib} GiB, ${_pct}% used" "" "" "$_pct"
}

walk_uptime() {
    _f=$(p /proc/uptime)
    [ -r "$_f" ] || return 0
    _sec=$(read1 "$_f" | awk '{ print int($1) }')
    [ -n "$_sec" ] || return 0
    _text=$(awk -v s="$_sec" 'BEGIN {
        d = int(s / 86400); h = int((s % 86400) / 3600); m = int((s % 3600) / 60)
        if (d > 0) printf "%dd %dh", d, h
        else if (h > 0) printf "%dh %dm", h, m
        else printf "%dm", m
    }')
    add "sys.uptime" "system" "Uptime" "$_text" "" "proc" "ok" "" "" ""
}

walk_net() {
    _base=$(p /sys/class/net)
    [ -d "$_base" ] || return 0
    for _d in "$_base"/*; do
        [ -e "$_d" ] || continue
        _name=$(basename "$_d")
        case $_name in
            lo|sit*|docker*|veth*|virbr*|cni*|podman*|br-*|tun*|tap*) continue ;;
        esac
        _state=$(read1 "$_d/operstate")
        _speed=$(read1 "$_d/speed")
        [ "$_speed" = "-1" ] && _speed=""
        _note=${_state:-link}
        if [ -n "$_speed" ] && [ "$_speed" != "0" ]; then
            _note="$_note ${_speed} Mb/s"
        fi
        if [ "$_state" = "up" ] || [ -n "$_speed" ]; then
            if [ -n "$_speed" ] && [ "$_speed" != "0" ]; then
                add "net.$_name" "nic" "$_name" "$_speed" "Mb/s" "net" "ok" "$_note" "" ""
            else
                add "net.$_name" "nic" "$_name" "$_state" "" "net" "ok" "$_note" "" ""
            fi
        fi
    done
}

walk_limits() {
    _f=$(p /usr/syno/etc/scemd.xml)
    [ -r "$_f" ] || _f=$(p /usr/syno/etc.defaults/scemd.xml)
    [ -r "$_f" ] || return 0
    awk '
        /<fan_config/ && !seen { inblock = 1; seen = 1 }
        inblock && /<\/fan_config>/ { exit }
        inblock && /shutdown_temp=/ {
            name = ""; temp = ""
            if (match($0, /name="[^"]+"/)) name = substr($0, RSTART + 6, RLENGTH - 7)
            if (match($0, /shutdown_temp="[0-9]+"/)) temp = substr($0, RSTART + 15, RLENGTH - 16)
            if (name != "" && temp != "") print name, temp
        }
    ' "$_f" | while read -r _name _temp; do
        [ -n "$_name" ] || continue
        add "limit.$_name" "system" "$_name shutdown" "$_temp" "C" "scemd" "ok" "shutdown threshold" "" ""
    done
}

walk_disks() {
    _dir=$(p /run/synostorage/disks)
    [ -d "$_dir" ] || return 0
    for _t in "$_dir"/*/temperature; do
        [ -f "$_t" ] || continue
        _disk=$(basename "$(dirname "$_t")")
        _raw=$(read1 "$_t")
        case $_raw in
            ""|*[!0-9.]*) continue ;;
        esac
        _label=$_disk
        _note=
        if [ -r "$(dirname "$_t")/model" ]; then
            _model=$(clean "$(read1 "$(dirname "$_t")/model")")
            [ -n "$_model" ] && _label="$_disk $_model"
        fi
        if [ -r "$(dirname "$_t")/remain_life" ]; then
            _life=$(read1 "$(dirname "$_t")/remain_life")
            [ -n "$_life" ] && _note="life ${_life}%"
        fi
        add "disk.$_disk" "disk" "$_label" "$_raw" "C" "/run/synostorage" "ok" "$_note" "" ""
    done
}

walk_thermal_zones() {
    _base=$(p /sys/class/thermal)
    [ -d "$_base" ] || return 0
    for _z in "$_base"/thermal_zone*; do
        [ -d "$_z" ] || continue
        _type=$(clean "$(read1 "$_z/type")")
        [ -n "$_type" ] || continue
        # hwmon walk already covered chips that also export a thermal zone.
        _dup=$(awk -F'\t' -v t="$_type" '$1 == "S" && $7 == t { found = 1 } END { print found+0 }' "$tsv")
        [ "$_dup" -gt 0 ] && continue
        _id=$(printf 'zone.%s' "$_type" | tr ' /' '__')
        add_temp_file "$_id" "board" "$_type" "$(read1 "$_z/temp")" "thermal_zone" "" ""
    done
}

host_model=$(read1 "$(p /proc/sys/kernel/syno_hw_version)")
host_unique=$(kv "$(p /etc.defaults/synoinfo.conf)" unique)
host_upnp=$(kv "$(p /etc.defaults/synoinfo.conf)" upnpmodelname)
host_dsm=$(kv "$(p /etc.defaults/VERSION)" productversion)
host_build=$(kv "$(p /etc.defaults/VERSION)" buildnumber)
host_fix=$(kv "$(p /etc.defaults/VERSION)" smallfixnumber)
host_cpu=$(awk -F: '/^(model name|Processor|Hardware|cpu model)/ { gsub(/^ /, "", $2); print $2; exit }' "$(p /proc/cpuinfo)" 2>/dev/null || true)
host_cpus=$(awk '/^processor[[:space:]]*:/ { n++ } END { print n+0 }' "$(p /proc/cpuinfo)" 2>/dev/null || echo 0)
host_name=${HARDWAREMONITOR_HOSTNAME:-$(hostname 2>/dev/null || echo nas)}
host_arch=$(uname -m 2>/dev/null || echo unknown)

walk_hwmon_tree() {
    _base=$(p /sys/class/hwmon)
    [ -d "$_base" ] || return 0
    for _d in "$_base"/hwmon*; do
        [ -d "$_d" ] || continue
        walk_hwmon "$_d"
    done
}

walk_hwmon_tree
walk_run_hwmon
walk_cpufreq
walk_rapl
walk_disks
walk_thermal_zones
walk_load
walk_mem
walk_uptime
walk_net
walk_limits

# Always say so when package power was not found. Chip power sensors use unit W
# and a source other than this placeholder.
_have_power=$(awk -F'\t' '$5 == "W" && $2 == "cpu" { found = 1 } END { print found+0 }' "$tsv")
if [ "$_have_power" -eq 0 ]; then
    _rapl=$(awk -F'\t' '$1 == "RAPL" { found = 1 } END { print found+0 }' "$tsv")
    if [ "$_rapl" -eq 0 ]; then
        add "cpu.package_power" "cpu" "Package power" "" "W" "powercap" "not_exposed" "no RAPL energy_uj and no hwmon power input" "" ""
    fi
fi

now=$(date +%s 2>/dev/null || echo 0)
json_tmp=$(mktemp "${TMPDIR:-/tmp}/hardwaremonitor.json.XXXXXX")
state_tmp=$(mktemp "${TMPDIR:-/tmp}/hardwaremonitor.state.XXXXXX")
trap 'rm -f "$tsv" "$json_tmp" "$state_tmp"' EXIT INT TERM

awk -F'\t' -v now="$now" -v state="$state" -v state_out="$state_tmp" \
    -v host="$host_name" -v model="$host_model" -v unique="$host_unique" \
    -v upnp="$host_upnp" -v dsm="$host_dsm" -v build="$host_build" -v fix="$host_fix" \
    -v cpu="$host_cpu" -v cpus="$host_cpus" -v arch="$host_arch" '
function jesc(s) {
    gsub(/\\/, "\\\\", s)
    gsub(/"/, "\\\"", s)
    gsub(/\r/, "", s)
    gsub(/\n/, " ", s)
    return s
}
function jstr(s) { return "\"" jesc(s) "\"" }
function isnum(s) { return s ~ /^-?[0-9]+(\.[0-9]+)?$/ }
function jval(s) {
    if (s == "") return "null"
    if (isnum(s)) return s
    return jstr(s)
}
function fan_index(id,    n) {
    n = id
    sub(/^.*fan/, "", n)
    if (n ~ /^[0-9]+$/) return n
    return ""
}
function abs(x) { return x < 0 ? -x : x }
BEGIN {
    if (state != "") {
        while ((getline line < state) > 0) {
            split(line, parts, "\t")
            if (parts[1] == "min") vmin[parts[2]] = parts[3]
            else if (parts[1] == "max") vmax[parts[2]] = parts[3]
            else if (parts[1] == "rapl") {
                rprev_uj[parts[2]] = parts[3]
                rprev_t[parts[2]] = parts[4]
            }
        }
        close(state)
    }
    dsmver = dsm
    if (build != "") dsmver = dsmver "-" build
    if (fix != "" && fix != "0") dsmver = dsmver "-" fix
    n = 0
}
$1 == "S" {
    n++
    id[n] = $2
    group[n] = $3
    label[n] = $4
    value[n] = $5
    unit[n] = $6
    source[n] = $7
    quality[n] = $8
    note[n] = $9
    limmax[n] = $10
    limcrit[n] = $11
    pct[n] = $12
    next
}
$1 == "RAPL" {
    z = $2
    uj = $3 + 0
    path = $4
    if (path in rprev_uj && (now - rprev_t[path]) >= 1 && (now - rprev_t[path]) <= 10) {
        du = uj - rprev_uj[path]
        dt = now - rprev_t[path]
        if (du < 0) du = du + 262144000000
        watts = du / dt / 1000000
        n++
        id[n] = "rapl." z
        group[n] = "cpu"
        label[n] = "RAPL " z
        value[n] = sprintf("%.2f", watts)
        unit[n] = "W"
        source[n] = "powercap"
        quality[n] = "ok"
        note[n] = "energy_uj delta"
        limmax[n] = ""
        limcrit[n] = ""
    }
    rnew_uj[path] = uj
    rnew_t[path] = now
    rnew_name[path] = z
    next
}
END {
    mismatch = 0
    for (i = 1; i <= n; i++) {
        fi = fan_index(id[i])
        if (fi == "") continue
        if (id[i] ~ /^dsm\.fan/) dsm_fan[fi] = value[i]
        else if (unit[i] == "RPM" && quality[i] == "ok") chip_fan[fi] = value[i]
    }
    for (fi in dsm_fan) {
        if (!(fi in chip_fan)) continue
        fa = dsm_fan[fi] + 0
        fb = chip_fan[fi] + 0
        if (fa <= 0 || fb <= 0) continue
        mid = (fa + fb) / 2
        if (mid > 0 && abs(fa - fb) / mid > 0.20) mismatch = 1
    }
    dsm_cpu = ""
    chip_cpu = ""
    for (i = 1; i <= n; i++) {
        if (id[i] ~ /^dsm\.CPU_/ && isnum(value[i])) dsm_cpu = value[i]
        if (source[i] == "coretemp" && label[i] ~ /Package/ && isnum(value[i])) chip_cpu = value[i]
    }
    if (dsm_cpu != "" && chip_cpu != "" && abs(dsm_cpu - chip_cpu) > 8) mismatch = 1

    have_power = 0
    for (i = 1; i <= n; i++) if (unit[i] == "W" && value[i] != "") have_power = 1
    if (!have_power) {
        waiting = 0
        for (path in rnew_uj) waiting = 1
        if (waiting) {
            n++
            id[n] = "cpu.package_power"
            group[n] = "cpu"
            label[n] = "Package power"
            value[n] = ""
            unit[n] = "W"
            source[n] = "powercap"
            quality[n] = "not_exposed"
            note[n] = "RAPL seen; watts appear on the next sample"
            limmax[n] = ""
            limcrit[n] = ""
        }
    }

    split("system cpu fans board voltage disk nic", order, " ")
    titles["system"] = "System"
    titles["cpu"] = "CPU"
    titles["fans"] = "Fans"
    titles["board"] = "Board"
    titles["voltage"] = "Voltage"
    titles["disk"] = "Disks"
    titles["nic"] = "NIC"

    printf "{\n"
    printf "  \"updated_unix\": %s,\n", now
    printf "  \"host\": {\n"
    printf "    \"hostname\": %s,\n", jstr(host)
    printf "    \"model\": %s,\n", jstr(model)
    printf "    \"unique\": %s,\n", jstr(unique)
    printf "    \"upnpmodelname\": %s,\n", jstr(upnp)
    printf "    \"dsm\": %s,\n", jstr(dsmver)
    printf "    \"cpu\": %s,\n", jstr(cpu)
    printf "    \"cpus\": %s,\n", cpus+0
    printf "    \"arch\": %s\n", jstr(arch)
    printf "  },\n"
    printf "  \"profile_mismatch\": %s,\n", (mismatch ? "true" : "false")
    printf "  \"groups\": [\n"
    gsep = ""
    for (oi = 1; oi <= 7; oi++) {
        g = order[oi]
        count = 0
        for (i = 1; i <= n; i++) if (group[i] == g) count++
        if (count == 0) continue
        printf "%s    {\n", gsep
        gsep = ",\n"
        printf "      \"id\": %s,\n", jstr(g)
        printf "      \"title\": %s,\n", jstr(titles[g])
        printf "      \"sensors\": [\n"
        ssep = ""
        for (i = 1; i <= n; i++) {
            if (group[i] != g) continue
            printf "%s        {\n", ssep
            ssep = ",\n"
            printf "          \"id\": %s,\n", jstr(id[i])
            printf "          \"label\": %s,\n", jstr(label[i])
            printf "          \"value\": %s,\n", jval(value[i])
            printf "          \"unit\": %s,\n", jstr(unit[i])
            printf "          \"source\": %s,\n", jstr(source[i])
            printf "          \"quality\": %s,\n", jstr(quality[i])
            printf "          \"note\": %s", jstr(note[i])
            if (pct[i] != "") printf ",\n          \"pct\": %s", jval(pct[i])
            if (quality[i] == "ok" || quality[i] == "suspect" || quality[i] == "stopped") {
                if (isnum(value[i])) {
                    if (!(id[i] in vmin) || value[i]+0 < vmin[id[i]]+0) vmin[id[i]] = value[i]
                    if (!(id[i] in vmax) || value[i]+0 > vmax[id[i]]+0) vmax[id[i]] = value[i]
                    printf ",\n          \"min\": %s,\n          \"max\": %s", jval(vmin[id[i]]), jval(vmax[id[i]])
                }
            }
            if (limmax[i] != "") printf ",\n          \"limit_max\": %s", jval(limmax[i])
            if (limcrit[i] != "") printf ",\n          \"limit_crit\": %s", jval(limcrit[i])
            printf "\n        }"
        }
        printf "\n      ]\n    }"
    }
    printf "\n  ]\n}\n"

    if (state_out != "") {
        for (k in vmin) printf "min\t%s\t%s\n", k, vmin[k] > state_out
        for (k in vmax) printf "max\t%s\t%s\n", k, vmax[k] > state_out
        for (path in rnew_uj) printf "rapl\t%s\t%s\t%s\n", path, rnew_uj[path], rnew_t[path] > state_out
        close(state_out)
    }
}
' "$tsv" > "$json_tmp"

if [ -n "$state" ]; then
    mv "$state_tmp" "$state"
fi
if [ -n "$snapshot" ]; then
    mv "$json_tmp" "$snapshot"
    chmod 644 "$snapshot" 2>/dev/null || true
else
    cat "$json_tmp"
fi
