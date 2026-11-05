#!/bin/sh
# Refresh web/chat_page.html from the sibling repo ../webchat, where the page
# is developed (the same page the firmware and the app serve). The server
# gzips it when it starts.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$HERE/../webchat"
[ -f "$WEB/tool/build.py" ] || { echo "webchat is not checked out next to this repo" >&2; exit 1; }
OUT="$(mktemp -d)"
python3 "$WEB/tool/build.py" --out "$OUT"
mkdir -p "$HERE/web"
cp "$OUT/chat_page.html" "$HERE/web/chat_page.html"
rm -rf "$OUT"
