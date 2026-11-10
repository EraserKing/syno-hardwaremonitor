#!/bin/sh
# Served by DSM from /webman/3rdparty/hardwaremonitor/snapshot.cgi.
# Read-only. Collects on demand into tmpfs and does not set fan mode.
printf 'Content-Type: application/json; charset=utf-8\r\n'
printf 'Cache-Control: no-store\r\n'
printf '\r\n'
helper=/var/packages/hardwaremonitor/target/bin/snapshot.sh
if [ -x "$helper" ]; then
    exec "$helper"
fi
printf '%s\n' '{"error":"snapshot helper missing"}'
