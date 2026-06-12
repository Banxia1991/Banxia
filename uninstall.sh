#!/usr/bin/env bash
# Remove the Shell MCP service.
# Usage: sudo bash uninstall.sh [domain]
#   (pass the domain to also remove its nginx site)
set -euo pipefail

DOMAIN="${1:-}"
SERVICE=mcp-shell
APP_DIR=/opt/mcp-shell

[ "$(id -u)" = "0" ] || { echo "run as root (use sudo)"; exit 1; }

systemctl disable --now ${SERVICE}.service 2>/dev/null || true
rm -f /etc/systemd/system/${SERVICE}.service
systemctl daemon-reload
rm -rf "$APP_DIR"
echo "removed service + $APP_DIR"

if [ -n "$DOMAIN" ]; then
  rm -f /etc/nginx/sites-enabled/${DOMAIN}.conf /etc/nginx/sites-available/${DOMAIN}.conf
  nginx -t && systemctl reload nginx || true
  echo "removed nginx site for $DOMAIN"
  echo "TLS cert left in place. To remove it too:  certbot delete --cert-name $DOMAIN"
else
  echo "pass a domain to also remove the nginx site:  sudo bash uninstall.sh <domain>"
fi
