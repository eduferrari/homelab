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
#   sudo public-access.sh check api.seudominio.com.br    # diagnóstico de um domínio
#   sudo public-access.sh acme-tls                       # Let's Encrypt só pela 443 (porta 80 bloqueada)
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

# Diagnóstico de um domínio público: DNS, firewall, proxy, rota no Traefik e certificado.
# De dentro da LAN não dá para provar o encaminhamento do roteador (NAT loopback) — o último
# passo mostra como confirmar com um acesso de fora.
check_domain() {
  local domain="$1" pub dns ok=0 cert issuer subject end code
  [[ -n "$domain" ]] || die "Uso: sudo $0 check <dominio>   ex.: api.seudominio.com.br"
  pass() { echo "  ✔ $*"; }
  fail() { echo "  ✘ $*"; ok=1; }
  warn() { echo "  ! $*"; }

  echo "Verificando $domain"
  pub="$(public_ip)"

  echo "1. DNS (resolvedor público 1.1.1.1)"
  dns="$(dig +short A "$domain" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)"
  if [[ -z "$dns" ]]; then
    fail "sem registro A — crie na zona do domínio: $domain  A  $pub  (no Registro.br, o nome é o que vem antes do domínio, ex.: api ou app.loja)"
  elif [[ "$dns" == "$pub" ]]; then
    pass "$domain → $dns"
  else
    fail "$domain → $dns, mas o IP público do L14 é $pub"
  fi

  echo "2. Firewall do L14"
  if ufw status | grep -q 'Proxy publico'; then pass "80/443 liberados (public-access.sh enable)"
  else fail "80/443 fechados para a internet — rode: sudo $0 enable"; fi

  echo "3. Proxy do Coolify"
  if ss -Hltn 'sport = :80' | grep -q . && ss -Hltn 'sport = :443' | grep -q .; then
    pass "escutando em 80 e 443"
  else
    fail "nada escutando em 80/443 — o coolify-proxy está rodando? (docker ps | grep coolify-proxy)"
  fi

  echo "4. Rota no Traefik (teste local, sem passar pelo roteador)"
  code="$(curl --noproxy "*" -s -o /dev/null -w '%{http_code}' -m 10 -k --resolve "$domain:443:127.0.0.1" "https://$domain/" 2>/dev/null || true)"
  code="${code:-000}"
  case "$code" in
    000) fail "sem resposta em https://$domain" ;;
    404) warn "HTTP 404 — normal se a raiz da app não tem rota; se o corpo for '404 page not found' (Traefik), falta a rota: Domains no Coolify ou labels Host(\`$domain\`)" ;;
    *)   pass "HTTP $code" ;;
  esac

  echo "5. Certificado"
  cert="$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$domain" 2>/dev/null | openssl x509 -noout -issuer -subject -enddate 2>/dev/null || true)"
  issuer="$(grep -m1 '^issuer' <<<"$cert" | sed 's/^issuer=//' || true)"
  subject="$(grep -m1 '^subject' <<<"$cert" | sed 's/^subject=//' || true)"
  end="$(grep -m1 '^notAfter' <<<"$cert" | cut -d= -f2- || true)"
  if [[ -z "$cert" ]]; then
    fail "não foi possível ler o certificado"
  elif grep -qi "let's encrypt" <<<"$issuer"; then
    pass "Let's Encrypt — válido até $end"
  elif [[ -s "$HOMELAB_DIR/ca/lan.crt" ]] && [[ "$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$domain" 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null)" == "$(openssl x509 -in "$HOMELAB_DIR/ca/lan.crt" -noout -fingerprint -sha256)" ]]; then
    fail "Let's Encrypt ainda não emitido — o Traefik entrega o certificado padrão da LAN (CA do homelab)"
    echo "     O desafio HTTP-01 precisa que a internet alcance a porta 80. Se o log disser"
    echo "     'reader size limit exceeded', a 80 é do roteador: use  sudo $0 acme-tls  (valida pela 443)."
    echo "     Veja o motivo:"
    echo "     docker logs coolify-proxy 2>&1 | grep -i -E 'acme|$domain' | tail"
  else
    fail "ainda não é Let's Encrypt (emissor: ${issuer:-?}; titular: ${subject:-?})"
    echo "     O desafio HTTP-01 precisa que a internet alcance a porta 80. Se o log disser"
    echo "     'reader size limit exceeded', a 80 é do roteador: use  sudo $0 acme-tls  (valida pela 443)."
    echo "     Veja o motivo:"
    echo "     docker logs coolify-proxy 2>&1 | grep -i -E 'acme|$domain' | tail"
  fi

  echo "6. Encaminhamento no roteador (precisa de um acesso de FORA da rede)"
  echo "     Deixe rodando:  sudo tcpdump -ni any 'tcp and (port 80 or port 443)' and not src net 192.168.0.0/16"
  echo "     e abra https://$domain pelo 4G do celular."
  echo "     Sem nenhuma linha → o roteador/provedor ainda não encaminha 80/443 para $(lan_ip)."
  echo
  if (( ok == 0 )); then echo "Tudo certo do lado do L14."; else echo "Há itens pendentes (✘) acima."; fi
  return "$ok"
}

# Let's Encrypt pelo desafio TLS-ALPN-01 (só porta 443) em vez do HTTP-01 (porta 80).
# Útil quando a porta 80 do IP público é do roteador/provedor ("reader size limit exceeded").
PROXY_COMPOSE="${COOLIFY_PROXY_DIR:-/data/coolify/proxy}/docker-compose.yml"
acme_tls() {
  local f="$PROXY_COMPOSE" bak
  [[ -f "$f" ]] || die "Não encontrei $f (Coolify instalado?)"
  if grep -q 'certificatesresolvers.letsencrypt.acme.tlschallenge=true' "$f"; then
    echo "✔ O resolver letsencrypt já usa TLS-ALPN-01 (porta 443)"; return 0
  fi
  grep -q 'certificatesresolvers.letsencrypt.acme.httpchallenge' "$f" \
    || die "Resolver letsencrypt com httpchallenge não encontrado em $f — ajuste manualmente"
  bak="$f.bak.$(date +%Y%m%d-%H%M%S)"; cp "$f" "$bak"
  sed -i -E \
    -e '/certificatesresolvers\.letsencrypt\.acme\.httpchallenge=true/d' \
    -e 's#certificatesresolvers\.letsencrypt\.acme\.httpchallenge\.entrypoint=[a-z0-9-]+#certificatesresolvers.letsencrypt.acme.tlschallenge=true#' \
    "$f"
  grep -q 'certificatesresolvers.letsencrypt.acme.tlschallenge=true' "$f" || { cp "$bak" "$f"; die "Edição falhou — arquivo restaurado"; }
  if ! docker compose -f "$f" config --quiet; then cp "$bak" "$f"; die "Compose inválido — arquivo restaurado ($bak)"; fi
  echo "==> Recriando o proxy (alguns segundos fora do ar)"
  if ! docker compose -f "$f" up -d; then
    cp "$bak" "$f"; docker compose -f "$f" up -d || true
    die "Proxy não subiu com a nova configuração — arquivo restaurado ($bak)"
  fi
  echo "✔ Let's Encrypt agora valida pela porta 443 (backup: $bak)"
  echo
  echo "IMPORTANTE: no Coolify, Servers → localhost → Proxy: confira que o editor mostra"
  echo "  --certificatesresolvers.letsencrypt.acme.tlschallenge=true  (e nenhum httpchallenge)"
  echo "e clique em Save — senão o próximo \"Restart Proxy\" volta ao HTTP-01."
  echo
  echo "Acompanhe a emissão:  docker logs -f coolify-proxy 2>&1 | grep -i acme"
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
  check)
    check_domain "${2:-}" ;;
  acme-tls) acme_tls ;;
  status) show_status ;;
  *) die "Uso: sudo $0 [status|enable|disable|check <dominio>|acme-tls]" ;;
esac
