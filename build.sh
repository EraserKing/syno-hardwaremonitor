#!/bin/sh
# Build an unsigned DSM 7 package. Run on this machine, install the .spk on the NAS.
set -eu
cd "$(dirname "$0")"
root=$(pwd)

bump_version() {
    case $1 in
        *-*) _base=${1%-*}; _build=${1##*-} ;;
        *) _base=$1; _build=0 ;;
    esac
    _num=$(printf '%s' "$_build" | sed 's/^0*//')
    case $_num in
        ""|*[!0-9]*) _num=0 ;;
    esac
    _num=$((_num + 1))
    printf '%s-%04d' "$_base" "$_num"
}

# spk/INFO is the source of truth. Every build gets a fresh build number, and
# the UI module filename + CSS cache key follow it automatically.
# Force a version with: VERSION=0.1.0-0020 ./build.sh
if [ -n "${VERSION:-}" ]; then
    pkgver=$VERSION
else
    pkgver=$(sed -n 's/^version="\(.*\)"$/\1/p' spk/INFO)
    [ -n "$pkgver" ] || { echo "build: no version= line in spk/INFO" >&2; exit 1; }
    while [ -e "$root/dist/hardwaremonitor-$pkgver.spk" ]; do
        pkgver=$(bump_version "$pkgver")
    done
    sed -i "s/^version=.*/version=\"$pkgver\"/" spk/INFO
fi
uiver=${pkgver##*-}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

python3 - "$root/ui/images" "$stage" <<'PY'
import struct, zlib, sys
from pathlib import Path

def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

def write_png(path, w, h, rgb):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw.extend(rgb[y * w * 3:(y + 1) * w * 3])
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    Path(path).write_bytes(data)

def canvas(size):
    px = bytearray(size * size * 3)
    bg = (18, 28, 36)
    fg = (127, 209, 195)
    cx = cy = (size - 1) / 2
    r = size * 0.36
    for y in range(size):
        for x in range(size):
            i = (y * size + x) * 3
            dx, dy = x - cx, y - cy
            d2 = dx * dx + dy * dy
            if d2 <= (size * 0.46) ** 2:
                px[i:i+3] = bg
            else:
                px[i:i+3] = (12, 16, 20)
            # three blades
            if d2 <= r * r and d2 >= (size * 0.08) ** 2:
                ang = (dx + dy) if dx or dy else 1
                if abs(dx) > abs(dy) * 0.35 and dy < size * 0.08:
                    px[i:i+3] = fg
                elif abs(dy) > abs(dx) * 0.35 and dx > -size * 0.08:
                    px[i:i+3] = fg
    return px

images = Path(sys.argv[1])
images.mkdir(parents=True, exist_ok=True)
stage = Path(sys.argv[2])
base = canvas(256)
write_png(images / "icon_256.png", 256, 256, base)
write_png(stage / "PACKAGE_ICON_256.PNG", 256, 256, base)
for size in (16, 24, 32, 48, 64, 72):
    small = bytearray(size * size * 3)
    for y in range(size):
        for x in range(size):
            sx = min(255, int(x * 256 / size))
            sy = min(255, int(y * 256 / size))
            si = (sy * 256 + sx) * 3
            di = (y * size + x) * 3
            small[di:di+3] = base[si:si+3]
    write_png(images / f"icon_{size}.png", size, size, small)
    if size == 72:
        write_png(stage / "PACKAGE_ICON.PNG", 72, 72, small)
print("icons ok")
PY

pkg="$stage/pkg"
mkdir -p "$pkg/bin" "$pkg/ui"
cp collect.sh "$pkg/bin/collect.sh"
chmod 755 "$pkg/bin/collect.sh"
# DSM 7 forbids run-as: root. The governor helper is a tiny freestanding
# setuid binary; conf/privilege installs it root:<package-group> 6550.
cc=${CC:-cc}
command -v "$cc" >/dev/null 2>&1 || {
    echo "build: $cc not found (needed to build the governor helper)" >&2
    exit 1
}
"$cc" -nostdlib -static -no-pie -s -O2 -fno-builtin -Wall -Wextra \
    -o "$pkg/bin/gov-helper" helper/gov-helper.c
chmod 755 "$pkg/bin/gov-helper"
cp ui/config ui/index.conf ui/style.css ui/snapshot.cgi ui/governor.cgi "$pkg/ui/"
# Versioned module name and CSS query so upgrades bypass DSM/browser caches.
sed -i "s/\"hardwaremonitor-ui[^\"]*\.js\"/\"hardwaremonitor-ui-$uiver.js\"/" "$pkg/ui/config"
cp ui/hardwaremonitor-ui.js "$pkg/ui/hardwaremonitor-ui-$uiver.js"
sed -i "s/style\.css?v=[0-9A-Za-z.-]*/style.css?v=$uiver/" "$pkg/ui/hardwaremonitor-ui-$uiver.js"
cp -a ui/images "$pkg/ui/images"
chmod 755 "$pkg/ui/snapshot.cgi" "$pkg/ui/governor.cgi"

mkdir -p "$stage/scripts" "$stage/conf"
sed "s/^version=.*/version=\"$pkgver\"/" spk/INFO > "$stage/INFO"
cp spk/conf/privilege "$stage/conf/privilege"
cp spk/scripts/* "$stage/scripts/"
chmod 755 "$stage/scripts/"*

tar -C "$pkg" -czf "$stage/package.tgz" .
mkdir -p "$root/dist"
spk="$root/dist/hardwaremonitor-$pkgver.spk"
tar -C "$stage" -cf "$spk" INFO package.tgz scripts conf PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG
echo "built $spk"
ls -lh "$spk"
