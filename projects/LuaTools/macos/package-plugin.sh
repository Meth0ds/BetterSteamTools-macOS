#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${1:-"$ROOT/luatools-plugin-macos.zip"}
rm_tmp=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp -R "$ROOT/plugin-macos/." "$TMP/"
(cd "$TMP" && /usr/bin/zip -qr "$OUT" .)
printf 'Created %s\n' "$OUT"
