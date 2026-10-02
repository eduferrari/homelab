#!/usr/bin/env bash
# shellcheck source=/dev/null
[[ -r "${HOMELAB_CONF:-/etc/homelab.conf}" ]] && . "${HOMELAB_CONF:-/etc/homelab.conf}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
# Libera o acesso da INTERNET ao proxy do Coolify (Traefik, portas 80/443) para apps com domínio.
# Todo o resto (Coolify :8000, bancos, RabbitMQ, SSH) continua só na LAN.
#
#   sudo public-access.sh status
#   sudo public-access.sh enable
#   sudo public-access.sh disable
set -Eeuo pipefail

ENV_FILE="$HOMELAB_DIR/infra/.env"
die() { echo "✘ $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo $0 $*"

set_env() {
  if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi
}

# O proxy do Coolify é um container: as portas publicadas passam pela cadeia DOCKER-USER, que só
# aceita redes privadas. Regras "route" do UFW entram em ufw-user-forward, consultada primeiro.
RULES=("proto tcp from any to any port 80" "proto tcp from any to any port 443" "proto udp from any to any port 443")

public_ip() { curl -fsS -m 5 https://api.ipify.org 2>/dev/null || echo "?"; }
lan_ip()    { hostname -I | awk '{print $1}'; }

show_status() {
  local state; state="$(grep -m1 '^PUBLIC_ACCESS=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  echo "Acesso público ..... ${state:-false}"
  echo "IP público ......... $(public_ip)"
  echo "IP na LAN .......... $(lan_ip)"
  echo "Regras públicas (UFW):"
  ufw status | grep -E 'Proxy publico' | sed 's/^/  /' || echo "  (nenhuma)"
}

case "${1:-status}" in
  enable)
    for r in "${RULES[@]}"; do
      # shellcheck disable=SC2086
      ufw route allow $r comment 'Proxy publico' >/dev/null
    done
    set_env PUBLIC_ACCESS true
    ufw reload >/dev/null
    echo "✔ Internet → proxy do Coolify liberado (80/tcp, 443/tcp, 443/udp)."
    echo
    show_status
    echo
    echo "Próximos passos:"
    echo "  1. No roteador/ONT: encaminhe as portas 80/tcp, 443/tcp e 443/udp para $(lan_ip)"
    echo "     (o L14 precisa de IP fixo na LAN — network-static.sh)."
    echo "  2. No DNS do seu domínio: registro A  ex.: api.seudominio.com.br → $(public_ip)"
    echo "  3. No Coolify, na aplicação: Domains = https://api.seudominio.com.br"
    echo "     (o Traefik emite o certificado Let's Encrypt automaticamente)."
    echo "  4. Teste de FORA da sua rede (ex.: 4G do celular): https://api.seudominio.com.br"
    ;;
  disable)
    for r in "${RULES[@]}"; do
      # shellcheck disable=SC2086
      ufw route delete allow $r >/dev/null 2>&1 || true
    done
    set_env PUBLIC_ACCESS false
    ufw reload >/dev/null
    echo "✔ Acesso da internet bloqueado. Lembre de remover o encaminhamento no roteador."
    ;;
  status) show_status ;;
  *) die "Uso: sudo $0 [status|enable|disable]" ;;
esac
