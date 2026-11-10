#!/bin/sh
# Refresh web/chat_page.html from the sibling repo ../portal, where the page
# is developed (the same page the firmware and the app serve). The server
# gzips it when it starts.
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$HERE/../portal"
[ -f "$WEB/tool/build.py" ] || { echo "portal is not checked out next to this repo" >&2; exit 1; }
OUT="$(mktemp -d)"
python3 "$WEB/tool/build.py" --out "$OUT"
mkdir -p "$HERE/web"
cp "$OUT/chat_page.html" "$HERE/web/chat_page.html"
rm -rf "$OUT"
# The compiled server carries the page inside itself (no file beside the binary).
# dart may be off PATH (build queues, services): fall back to the Flutter SDK's.
DART="$(command -v dart || echo "$HOME/flutter/bin/dart")"
[ -x "$DART" ] || { echo "dart not found (put it on PATH)" >&2; exit 1; }
(cd "$HERE" && "$DART" run tool/embed_page.dart)
