#!/bin/sh
# Served by DSM from /webman/3rdparty/hardwaremonitor/snapshot.cgi.
# Read-only. Does not set fan mode.
printf 'Content-Type: application/json; charset=utf-8\r\n'
printf 'Cache-Control: no-store\r\n'
printf '\r\n'
if [ -r /var/packages/hardwaremonitor/var/snapshot.json ]; then
    cat /var/packages/hardwaremonitor/var/snapshot.json
else
    printf '%s\n' '{"error":"snapshot not ready"}'
fi
