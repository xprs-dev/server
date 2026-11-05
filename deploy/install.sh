#!/bin/sh
# Install the built server as a systemd service (run with sudo, after
# `dart compile exe bin/xprs_server.dart -o build/xprs-server`).
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ -x "$HERE/build/xprs-server" ] || { echo "build/xprs-server missing" >&2; exit 1; }
[ -f "$HERE/web/chat_page.html" ] || { echo "web/chat_page.html missing (tool/sync_web_chat.sh)" >&2; exit 1; }
id xprs >/dev/null 2>&1 || useradd --system --home-dir /var/lib/xprs-server --shell /usr/sbin/nologin xprs
install -d /opt/xprs-server/web
install -m 0755 "$HERE/build/xprs-server" /opt/xprs-server/xprs-server
install -m 0644 "$HERE/web/chat_page.html" /opt/xprs-server/web/chat_page.html
install -m 0644 "$HERE/deploy/xprs-server.service" /etc/systemd/system/xprs-server.service
systemctl daemon-reload
systemctl enable --now xprs-server
echo "installed; logs: journalctl -u xprs-server -f"
