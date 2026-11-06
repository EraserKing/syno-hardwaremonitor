#!/bin/sh
# CPU governor endpoint.
#
# GET  -> current driver, dynamically reported governors, per-core state.
# POST -> action=set, administrators only. The package runs as its service
#         account; writes go through a narrow setuid helper installed by
#         conf/privilege (root:<package-group> 6550).
#
# The governor list is always read from the kernel, never hardcoded.
set -u

PKG_ROOT=${HARDWAREMONITOR_PKG_ROOT:-/var/packages/hardwaremonitor}
CPU_BASE=${HARDWAREMONITOR_CPU_BASE:-/sys/devices/system/cpu}
AUTH_CGI=${HARDWAREMONITOR_AUTH_CGI:-/usr/syno/synoman/webman/modules/authenticate.cgi}
ADMIN_GID=${HARDWAREMONITOR_ADMIN_GID:-101}
HELPER=${HARDWAREMONITOR_HELPER:-$PKG_ROOT/target/bin/gov-helper}

printf 'Content-Type: application/json; charset=utf-8\r\n'
printf 'Cache-Control: no-store\r\n'
printf '\r\n'

json_esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n'
}

json_str() {
    printf '"%s"' "$(json_esc "$1")"
}

read_first() {
    awk 'NR == 1 { print; exit }' "$1" 2>/dev/null
}

BODY=
if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
    _len=${CONTENT_LENGTH:-0}
    case $_len in
        ""|*[!0-9]*) _len=0 ;;
    esac
    if [ "$_len" -gt 0 ]; then
        BODY=$(dd bs=1 count="$_len" 2>/dev/null)
    fi
fi

param() {
    _key=$1
    # Command substitution runs in a subshell, so disabling globbing here is
    # local to this call.
    set -f
    for _src in "${QUERY_STRING:-}" "$BODY"; do
        _old_ifs=$IFS
        IFS='&'
        for _pair in $_src; do
            case $_pair in
                "$_key"=*)
                    IFS=$_old_ifs
                    printf '%s' "${_pair#*=}"
                    return 0
                    ;;
            esac
        done
        IFS=$_old_ifs
    done
    printf ''
}

# --- identity -------------------------------------------------------------
# DSM does not authenticate third-party CGI for us. authenticate.cgi prints the
# logged-in user and prints nothing when there is no session.
AUTH_USER=
if [ -x "$AUTH_CGI" ]; then
    AUTH_USER=$("$AUTH_CGI" 2>/dev/null | head -n 1)
fi
IS_ADMIN=0
if [ -n "$AUTH_USER" ]; then
    case " $(id -G "$AUTH_USER" 2>/dev/null) " in
        *" $ADMIN_GID "*) IS_ADMIN=1 ;;
    esac
fi

# --- current state --------------------------------------------------------
DRIVER=$(read_first "$CPU_BASE/cpu0/cpufreq/scaling_driver")

AVAIL=
for _f in "$CPU_BASE"/cpu[0-9]*/cpufreq/scaling_available_governors; do
    [ -r "$_f" ] || continue
    for _g in $(read_first "$_f"); do
        case " $AVAIL " in
            *" $_g "*) ;;
            *) AVAIL="$AVAIL $_g" ;;
        esac
    done
done
AVAIL=${AVAIL# }

CORES=
for _d in "$CPU_BASE"/cpu[0-9]*/cpufreq; do
    [ -d "$_d" ] || continue
    _c=${_d%/cpufreq}
    _c=${_c##*/}
    _g=$(read_first "$_d/scaling_governor")
    _min=$(read_first "$_d/cpuinfo_min_freq")
    _max=$(read_first "$_d/cpuinfo_max_freq")
    _minmhz=
    _maxmhz=
    case $_min in
        ""|*[!0-9]*) ;;
        *) _minmhz=$((_min / 1000)) ;;
    esac
    case $_max in
        ""|*[!0-9]*) ;;
        *) _maxmhz=$((_max / 1000)) ;;
    esac
    CORES="$CORES $_c|$_g|$_minmhz|$_maxmhz"
done
CORES=${CORES# }

emit_state() {
    printf '{"success":true,"user":'
    if [ -n "$AUTH_USER" ]; then json_str "$AUTH_USER"; else printf 'null'; fi
    printf ',"admin":%s,"driver":%s,"available":[' "$IS_ADMIN" "$(json_str "$DRIVER")"
    _sep=
    for _g in $AVAIL; do
        printf '%s%s' "$_sep" "$(json_str "$_g")"
        _sep=','
    done
    printf '],"cores":['
    _sep=
    for _row in $CORES; do
        _c=${_row%%|*}
        _rest=${_row#*|}
        _g=${_rest%%|*}
        _rest=${_rest#*|}
        _min=${_rest%%|*}
        _max=${_rest#*|}
        printf '%s{"id":%s,"governor":%s,"min_mhz":%s,"max_mhz":%s}' \
            "$_sep" "$(json_str "$_c")" "$(json_str "$_g")" "${_min:-null}" "${_max:-null}"
        _sep=','
    done
    printf ']}\n'
}

# --- write path -----------------------------------------------------------
valid_gov() {
    _want=$1
    case $_want in
        ""|*[!a-zA-Z0-9_-]*) return 1 ;;
    esac
    case " $AVAIL " in
        *" $_want "*) return 0 ;;
    esac
    return 1
}

apply_target() {
    _target=$1
    _want=$2
    _out=$("$HELPER" "$_target" "$_want" 2>/dev/null) || true
    _a=${_out%% *}
    _f=${_out##* }
    case $_a in
        ""|*[!0-9]*) _a=0 ;;
    esac
    case $_f in
        ""|*[!0-9]*) _f=1 ;;
    esac
    APPLIED=$((APPLIED + _a))
    FAILED=$((FAILED + _f))
    LAST=$_want
}

ACTION=$(param action)
if [ "$ACTION" = "set" ]; then
    if [ "${REQUEST_METHOD:-GET}" != "POST" ]; then
        printf '%s\n' '{"success":false,"error":"POST required"}'
        exit 0
    fi
    if [ -z "$AUTH_USER" ]; then
        printf '%s\n' '{"success":false,"error":"unauthorized - sign in to DSM"}'
        exit 0
    fi
    if [ "$IS_ADMIN" -ne 1 ]; then
        printf '%s\n' '{"success":false,"error":"administrators only"}'
        exit 0
    fi
    # Cheap CSRF guard: browser requests from the DSM UI carry our own host.
    if [ -n "${HTTP_REFERER:-}" ]; then
        case "$HTTP_REFERER" in
            "http://${HTTP_HOST:-none}/"*|"https://${HTTP_HOST:-none}/"*) ;;
            *)
                printf '%s\n' '{"success":false,"error":"cross-origin request rejected"}'
                exit 0
                ;;
        esac
    fi
    if [ ! -x "$HELPER" ]; then
        printf '%s\n' '{"success":false,"error":"governor helper is not available; rebuild the package for this CPU architecture"}'
        exit 0
    fi

    APPLIED=0
    FAILED=0
    LAST=
    _rejected=0

    _all=$(param all)
    if [ -n "$_all" ]; then
        if valid_gov "$_all"; then
            _count=0
            for _row in $CORES; do
                _c=${_row%%|*}
                apply_target "$_c" "$_all"
                _count=$((_count + 1))
            done
            [ "$_count" -gt 0 ] || _rejected=$((_rejected + 1))
        else
            _rejected=$((_rejected + 1))
        fi
    fi

    for _d in "$CPU_BASE"/cpu[0-9]*/cpufreq; do
        [ -d "$_d" ] || continue
        _c=${_d%/cpufreq}
        _c=${_c##*/}
        _v=$(param "$_c")
        [ -n "$_v" ] || continue
        if valid_gov "$_v"; then
            apply_target "$_c" "$_v"
        else
            _rejected=$((_rejected + 1))
        fi
    done

    if [ "$APPLIED" -eq 0 ] && [ "$FAILED" -eq 0 ] && [ "$_rejected" -eq 0 ]; then
        printf '%s\n' '{"success":false,"error":"no governor change requested"}'
    elif [ "$APPLIED" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
        printf '{"success":false,"rejected":%s,"error":"no valid governor change requested"}\n' "$_rejected"
    elif [ "$APPLIED" -eq 0 ]; then
        printf '{"success":false,"applied":0,"failed":%s,"rejected":%s,"error":"governor change rejected by the kernel"}\n' \
            "$FAILED" "$_rejected"
    else
        _msg="$LAST applied to $APPLIED core(s)"
        [ "$FAILED" -eq 0 ] || _msg="$_msg, $FAILED rejected by the kernel"
        [ "$_rejected" -eq 0 ] || _msg="$_msg, $_rejected invalid"
        printf '{"success":true,"applied":%s,"failed":%s,"rejected":%s,"message":%s}\n' \
            "$APPLIED" "$FAILED" "$_rejected" "$(json_str "$_msg")"
    fi
    exit 0
fi

emit_state
