#!/usr/bin/env bash
# =============================================================================
# One-shot deployer for the Shell MCP service.
# Tested on Alibaba Cloud Ubuntu 24.04 / 26.04 (Debian-family).
#
# Usage:
#   sudo bash deploy.sh <domain> [letsencrypt-email]
#
# Example:
#   sudo bash deploy.sh mcp.example.com ops@example.com
#
# PREREQUISITES (do these BEFORE running):
#   1. DNS A record for <domain> -> THIS server's public IP.
#   2. Inbound ports 80 AND 443 open in the cloud security group / firewall.
#
# Result: a public MCP endpoint at  https://<domain>/mcp
#         Add that URL as a custom connector in Claude.ai.
# =============================================================================
set -euo pipefail

DOMAIN="${1:-}"
EMAIL="${2:-}"
APP_DIR=/opt/mcp-shell
PORT=8765
SERVICE=mcp-shell
WEBROOT=/var/www/html

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo; echo "=== $* ==="; }

[ "$(id -u)" = "0" ] || die "run as root (use sudo)"
[ -n "$DOMAIN" ] || die "usage: sudo bash deploy.sh <domain> [letsencrypt-email]"

SRC="$(cd "$(dirname "$0")" && pwd)"
for f in server.py nginx-http.conf.template nginx-https.conf.template; do
  [ -f "$SRC/$f" ] || die "missing $f next to deploy.sh"
done

log "1/9 prerequisite checks"
PUBIP="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || curl -fsS --max-time 8 http://ifconfig.me 2>/dev/null || true)"
RESV="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)"
echo "this server public IP : ${PUBIP:-unknown}"
echo "domain resolves to    : ${RESV:-NOT RESOLVING}   ($DOMAIN)"
[ -n "$RESV" ] || die "$DOMAIN does not resolve. Create a DNS A record -> ${PUBIP:-this server} first."
if [ -n "$PUBIP" ] && [ "$PUBIP" != "$RESV" ]; then
  echo "WARNING: $DOMAIN points to $RESV but this server is $PUBIP."
  echo "         Let's Encrypt will FAIL unless the A record points here. Continuing in 5s (Ctrl-C to abort)..."
  sleep 5
fi

log "2/9 install packages (nginx, certbot, python venv)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx certbot python3-venv python3-pip curl

PYV="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
python3 -c 'import sys;exit(0 if sys.version_info[:2]>=(3,10) else 1)' \
  || die "Python >= 3.10 required by the mcp SDK (found $PYV)"
echo "python $PYV ok"

log "3/9 create venv and install the mcp SDK"
mkdir -p "$APP_DIR"
[ -d "$APP_DIR/venv" ] || python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q --upgrade pip
"$APP_DIR/venv/bin/pip" install -q mcp
echo "mcp installed: $("$APP_DIR/venv/bin/python" -c 'import mcp,importlib.metadata as m;print(m.version("mcp"))')"

log "4/9 install server.py"
install -m 0644 "$SRC/server.py" "$APP_DIR/server.py"
"$APP_DIR/venv/bin/python" -c "import ast,sys;ast.parse(open('$APP_DIR/server.py').read())" \
  || die "server.py failed to parse"

log "5/9 systemd service"
cat > /etc/systemd/system/${SERVICE}.service <<UNIT
[Unit]
Description=Shell MCP Server (streamable-http)
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
Environment=MCP_HOST=127.0.0.1
Environment=MCP_PORT=$PORT
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now ${SERVICE}.service
sleep 3
systemctl is-active --quiet ${SERVICE}.service \
  || { journalctl -u ${SERVICE} -n 25 --no-pager; die "service failed to start"; }
(ss -ltn 2>/dev/null || netstat -ltn) | grep -q "127.0.0.1:$PORT" \
  || die "backend not listening on 127.0.0.1:$PORT"
echo "backend healthy on 127.0.0.1:$PORT"

log "6/9 nginx HTTP config + ACME webroot"
mkdir -p "$WEBROOT"
sed "s/__DOMAIN__/$DOMAIN/g; s/__PORT__/$PORT/g" "$SRC/nginx-http.conf.template" \
  > /etc/nginx/sites-available/${DOMAIN}.conf
ln -sf /etc/nginx/sites-available/${DOMAIN}.conf /etc/nginx/sites-enabled/${DOMAIN}.conf
nginx -t
systemctl reload nginx

log "7/9 obtain TLS certificate (Let's Encrypt, webroot)"
if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
  echo "certificate already present, skipping issuance"
elif [ -n "$EMAIL" ]; then
  certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"
else
  certbot certonly --webroot -w "$WEBROOT" -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
fi
[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] \
  || die "certificate not issued. Check that ports 80/443 are open in the security group and DNS points here."

log "8/9 nginx HTTPS final config"
sed "s/__DOMAIN__/$DOMAIN/g; s/__PORT__/$PORT/g" "$SRC/nginx-https.conf.template" \
  > /etc/nginx/sites-available/${DOMAIN}.conf
nginx -t
systemctl reload nginx

log "9/9 verify end-to-end over HTTPS"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"deploy","version":"1"}}}'
CODE="$(curl -s -o /tmp/mcp_verify.txt -w '%{http_code}' --max-time 15 -X POST "https://$DOMAIN/mcp" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$INIT")"
echo "initialize -> HTTP $CODE"
if grep -q '"serverInfo"' /tmp/mcp_verify.txt && grep -q 'protocolVersion' /tmp/mcp_verify.txt; then
  echo "MCP handshake OK"
else
  die "verification failed (HTTP $CODE): $(head -c 200 /tmp/mcp_verify.txt)"
fi

cat <<DONE

==================================================================
 Done. Shell MCP service is live.

   Connector URL (Claude.ai -> Settings -> Connectors -> Add custom):
       https://$DOMAIN/mcp

   Manage:   systemctl status $SERVICE
   Logs:     journalctl -u $SERVICE -f
   Backend:  127.0.0.1:$PORT  (loopback only, exposed via nginx + TLS)
   Renewal:  automatic (certbot timer); nginx serves the ACME challenge.

 !!  This endpoint has NO authentication. Anyone with the URL can run
     shell commands on this server. See README.md -> "Security" to harden.
==================================================================
DONE
