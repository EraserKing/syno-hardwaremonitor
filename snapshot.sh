#!/bin/sh
# On-demand snapshot with a short cache in tmpfs.
#
# Prints the snapshot JSON to stdout. The collector runs only when the cached
# sample is older than TTL, so nothing runs while no window or poller is
# asking for data.
#
# HARDWAREMONITOR_SHM   cache directory (default /dev/shm/hardwaremonitor)
# HARDWAREMONITOR_TTL   seconds a sample stays valid (default 1)
set -u

PKGDEST=${SYNOPKG_PKGDEST:-/var/packages/hardwaremonitor/target}
SHM=${HARDWAREMONITOR_SHM:-/dev/shm/hardwaremonitor}
TTL=${HARDWAREMONITOR_TTL:-1}
SNAP="$SHM/snapshot.json"
STATE="$SHM/state"
LOCK="$SHM/collect.lock"

case $TTL in
    ''|*[!0-9]*) TTL=1 ;;
esac

fail() {
    printf '{"error":"%s"}\n' "$1"
    exit 0
}

mkdir -p "$SHM" 2>/dev/null || true
[ -d "$SHM" ] || fail "cache directory unavailable"

mtime() {
    stat -c %Y "$1" 2>/dev/null || date -r "$1" +%s 2>/dev/null || echo 0
}

age_of() {
    _mt=$(mtime "$1")
    if [ "$_mt" -le 0 ] 2>/dev/null; then
        echo 999999
        return
    fi
    echo $(( $(date +%s) - _mt ))
}

fresh() {
    [ -s "$SNAP" ] || return 1
    [ "$(age_of "$SNAP")" -lt "$TTL" ]
}

collect() {
    tmp="$SNAP.$$"
    if TMPDIR="$SHM" \
       HARDWAREMONITOR_SNAPSHOT="$tmp" \
       HARDWAREMONITOR_STATE="$STATE" \
       sh "$PKGDEST/bin/collect.sh" >/dev/null 2>&1 && [ -s "$tmp" ]; then
        chmod 644 "$tmp" 2>/dev/null || true
        mv "$tmp" "$SNAP"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# A collector that died can leave the lock behind.
if [ -d "$LOCK" ] && [ "$(age_of "$LOCK")" -gt 30 ]; then
    rmdir "$LOCK" 2>/dev/null || true
fi

if fresh; then
    cat "$SNAP"
    exit 0
fi

if mkdir "$LOCK" 2>/dev/null; then
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
    collect || true
    rmdir "$LOCK" 2>/dev/null || true
    trap - EXIT INT TERM
else
    # Another request is collecting. Serve what exists rather than starting a
    # second collector; only wait when there is no snapshot at all yet.
    _i=0
    while [ "$_i" -lt 3 ] && [ ! -s "$SNAP" ]; do
        sleep 1
        _i=$((_i + 1))
    done
fi

if [ -s "$SNAP" ]; then
    cat "$SNAP"
else
    fail "snapshot not ready"
fi
