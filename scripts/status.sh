#!/usr/bin/env bash
# Visão rápida do homelab
# shellcheck source=/dev/null
[[ -r "${HOMELAB_CONF:-/etc/homelab.conf}" ]] && . "${HOMELAB_CONF:-/etc/homelab.conf}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
ENV_FILE="$HOMELAB_DIR/infra/.env"
envget() { grep -m1 "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true; }

IP="$(hostname -I | awk '{print $1}')"
HOST="$(hostname).local"
echo "== Rede =="
echo "IP: $IP | mDNS: $HOST | público: $(envget HOMELAB_PUBLIC_IP)"
echo
echo "== Stack (MySQL, Redis, RabbitMQ) =="
docker compose -f "$HOMELAB_DIR/infra/docker-compose.yml" ps --format 'table {{.Name}}\t{{.Status}}'
echo
echo "== Proxy (Traefik) =="
if docker inspect traefik >/dev/null 2>&1; then
  docker inspect -f '{{.Config.Image}} | {{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}' traefik
  echo "Detalhes: sudo $HOMELAB_DIR/scripts/proxy.sh status"
else
  echo "não instalado (sudo $HOMELAB_DIR/scripts/proxy.sh apply)"
fi
echo
echo "== Painéis (só LAN) =="
for c in painel:9440 dozzle:9443 goaccess-web:9444 uptime-kuma:9445 seq:9446; do
  n="${c%%:*}"; s="$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null || echo '-')"
  [[ "$s" == "-" ]] || printf '%-14s %-10s https://%s:%s\n' "$n" "$s" "$HOST" "${c##*:}"
done
echo
echo "== Projetos ($HOMELAB_DIR/apps) =="
for d in "$HOMELAB_DIR"/apps/*/; do
  [[ -f "$d/docker-compose.yml" || -f "$d/compose.yml" ]] || continue
  printf '%-14s %s\n' "$(basename "$d")" "$(docker compose --project-directory "$d" ps --format '{{.Service}}:{{.State}}' 2>/dev/null | xargs || echo '?')"
done
echo
echo "== Firewall =="; sudo ufw status | head -12
echo; echo "== Disco =="; df -h / | tail -1
echo; echo "== Bateria =="; cat /sys/class/power_supply/BAT0/capacity 2>/dev/null | sed 's/$/%/' || echo "n/d"
echo; echo "== Certificado da LAN =="
if [[ -f "$HOMELAB_DIR/ca/lan.crt" ]]; then
  openssl x509 -in "$HOMELAB_DIR/ca/lan.crt" -noout -enddate -ext subjectAltName 2>/dev/null | sed 's/^/  /'
else
  echo "  não emitido (sudo $HOMELAB_DIR/scripts/homelab-ca.sh)"
fi
echo; echo "== Backup =="
echo "Último backup completo: $(readlink "$HOMELAB_DIR/backups/latest" 2>/dev/null || echo 'nenhum')"
if [[ -r "$HOMELAB_DIR/backups/last-status.json" ]]; then
  jq -r '"Última execução: \(.time) | \(if .ok then "OK" else "FALHOU" end) | \(.message)"' "$HOMELAB_DIR/backups/last-status.json" 2>/dev/null || true
fi
systemctl list-timers homelab-backup.timer --no-pager 2>/dev/null | sed -n 2p
EXT_MNT="$(envget BACKUP_EXTERNAL_MOUNT)"; EXT_DIR="$(envget BACKUP_EXTERNAL_DIR)"
if [[ -z "$EXT_MNT" ]]; then
  echo "SSD externo: não configurado (sudo $HOMELAB_DIR/scripts/backup-disk-setup.sh)"
elif mountpoint -q "$EXT_MNT"; then
  echo "SSD externo: montado em $EXT_MNT | livre $(df -h --output=avail "$EXT_MNT" | tail -1 | tr -d ' ') | último: $(readlink "$EXT_DIR/latest" 2>/dev/null || echo 'nenhum')"
else
  echo "SSD externo: ⚠️  NÃO montado em $EXT_MNT — conecte o disco"
fi
