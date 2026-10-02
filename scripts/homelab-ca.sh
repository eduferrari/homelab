#!/usr/bin/env bash
# CA local do homelab — HTTPS na LAN (nome .local e IP) pelo proxy do Coolify (Traefik).
#
#   sudo homelab-ca.sh                       # status (CA, certificado, integração com o Coolify)
#   sudo homelab-ca.sh import-caddy [VOL]    # reaproveita a CA de um Caddy antigo (dispositivos continuam confiando)
#   sudo homelab-ca.sh init                  # cria uma CA nova (só se não houver nenhuma)
#   sudo homelab-ca.sh issue [nome ...]      # emite o certificado da LAN e instala no Traefik do Coolify
#   sudo homelab-ca.sh renew                 # reemite se faltar menos de 30 dias (usado pelo timer semanal)
#   sudo homelab-ca.sh export [ARQUIVO]      # exporta o certificado raiz para instalar em dispositivos
#
# O certificado também é configurado como PADRÃO do Traefik: clientes que acessam pelo IP não
# enviam SNI (ex.: tablets Android) e recebem este certificado em vez do auto-assinado do Traefik.
set -Eeuo pipefail
# shellcheck source=/dev/null
[[ -r "${HOMELAB_CONF:-/etc/homelab.conf}" ]] && . "${HOMELAB_CONF:-/etc/homelab.conf}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
ENV_FILE="$HOMELAB_DIR/infra/.env"
CA_DIR="$HOMELAB_DIR/ca"
COOLIFY_PROXY="${COOLIFY_PROXY_DIR:-/data/coolify/proxy}"
LEAF_DAYS="${LEAF_DAYS:-365}"         # dispositivos Apple aceitam no máximo 825 dias para CAs privadas
RENEW_BEFORE_DAYS=30

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log() { echo "==> $*"; }
die() { echo "✘ $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo $0 $*"

envget() { grep -m1 "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true; }
lan_host() { local h; h="$(envget HOMELAB_HOST)"; echo "${h:-$(hostname).local}"; }
lan_ip()   { local i; i="$(envget HOMELAB_IP)";   echo "${i:-$(hostname -I | awk '{print $1}')}"; }
fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }

have_ca() { [[ -s "$CA_DIR/root.crt" && -s "$CA_DIR/root.key" ]]; }

save_ca() {   # $1=crt $2=key (arquivos temporários)
  openssl x509 -in "$1" -noout >/dev/null 2>&1 || die "Certificado raiz inválido"
  openssl pkey -in "$2" -noout >/dev/null 2>&1 || die "Chave da CA inválida"
  # chave e certificado precisam ser do mesmo par
  [[ "$(openssl x509 -in "$1" -noout -pubkey)" == "$(openssl pkey -in "$2" -pubout)" ]] \
    || die "A chave não corresponde ao certificado raiz"
  install -d -m 700 -o root -g root "$CA_DIR"
  install -m 644 -o root -g root "$1" "$CA_DIR/root.crt"
  install -m 600 -o root -g root "$2" "$CA_DIR/root.key"
}

cmd_init() {
  have_ca && die "Já existe uma CA em $CA_DIR — não sobrescrevo (os dispositivos confiam nela)"
  local tmp; tmp="$(mktemp -d -p "$WORK")"
  log "Criando CA nova (EC P-256, 10 anos)"
  openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/root.key"
  openssl req -x509 -new -key "$tmp/root.key" -sha256 -days 3650 \
    -subj "/CN=Homelab Local CA ($(hostname))" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$tmp/root.crt"
  save_ca "$tmp/root.crt" "$tmp/root.key"
  log "CA criada — SHA-256: $(fingerprint "$CA_DIR/root.crt")"
  echo "  Instale o certificado raiz nos dispositivos: sudo $0 export"
}

cmd_import_caddy() {
  have_ca && die "Já existe uma CA em $CA_DIR — não sobrescrevo"
  local vol="${1:-}" v img tmp
  if [[ -z "$vol" ]]; then
    for v in homelab_caddy_data mesafacil_caddy_data; do
      docker volume inspect "$v" >/dev/null 2>&1 && { vol="$v"; break; }
    done
  fi
  [[ -n "$vol" ]] || die "Volume do Caddy não encontrado. Informe: sudo $0 import-caddy <volume>"
  img="$(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -m1 -E '^(redis|alpine|busybox|caddy)' || echo busybox:latest)"
  tmp="$(mktemp -d -p "$WORK")"
  log "Importando a CA do volume $vol"
  docker run --rm -v "$vol":/d:ro --entrypoint cat "$img" /d/caddy/pki/authorities/local/root.crt > "$tmp/root.crt" \
    || die "root.crt não encontrado em $vol"
  docker run --rm -v "$vol":/d:ro --entrypoint cat "$img" /d/caddy/pki/authorities/local/root.key > "$tmp/root.key" \
    || die "root.key não encontrado em $vol"
  save_ca "$tmp/root.crt" "$tmp/root.key"
  log "CA importada — SHA-256: $(fingerprint "$CA_DIR/root.crt")"
  echo "  Deve ser a MESMA impressão digital instalada nos dispositivos."
}

cmd_issue() {
  have_ca || die "Nenhuma CA. Use: sudo $0 import-caddy  (reaproveitar)  ou  sudo $0 init  (nova)"
  local host ip extra names san tmp
  host="$(lan_host)"; ip="$(lan_ip)"
  extra="$(envget HOMELAB_CA_EXTRA_NAMES)"
  # shellcheck disable=SC2206
  names=("$host" $extra "$@")
  san="IP:${ip}"
  local n; for n in "${names[@]}"; do
    [[ -n "$n" ]] || continue
    if [[ "$n" =~ ^[0-9.]+$ ]]; then san+=",IP:$n"; else san+=",DNS:$n"; fi
  done
  tmp="$(mktemp -d -p "$WORK")"
  log "Emitindo certificado da LAN ($san, ${LEAF_DAYS} dias)"
  openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/lan.key"
  openssl req -new -key "$tmp/lan.key" -subj "/CN=${host}" -out "$tmp/lan.csr"
  cat > "$tmp/ext.cnf" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=${san}
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EXT
  openssl x509 -req -in "$tmp/lan.csr" -CA "$CA_DIR/root.crt" -CAkey "$CA_DIR/root.key" \
    -CAcreateserial -CAserial "$tmp/root.srl" -days "$LEAF_DAYS" -sha256 \
    -extfile "$tmp/ext.cnf" -out "$tmp/lan.crt" 2>/dev/null
  openssl verify -CAfile "$CA_DIR/root.crt" "$tmp/lan.crt" >/dev/null || die "Certificado emitido não valida contra a CA"
  install -m 644 "$tmp/lan.crt" "$CA_DIR/lan.crt"
  install -m 600 "$tmp/lan.key" "$CA_DIR/lan.key"
  install_traefik
}

install_traefik() {
  if [[ ! -d "$COOLIFY_PROXY" ]]; then
    echo "  Coolify não encontrado em $COOLIFY_PROXY — certificado salvo em $CA_DIR/lan.{crt,key}."
    echo "  Depois de instalar o Coolify, rode: sudo $0 issue"
    return 0
  fi
  install -d -m 755 "$COOLIFY_PROXY/certs" "$COOLIFY_PROXY/dynamic"
  install -m 644 "$CA_DIR/lan.crt" "$COOLIFY_PROXY/certs/homelab-lan.crt"
  install -m 600 "$CA_DIR/lan.key" "$COOLIFY_PROXY/certs/homelab-lan.key"
  cat > "$COOLIFY_PROXY/dynamic/homelab-lan.yaml" <<'YAML'
# Gerado por homelab-ca.sh — certificado da LAN (CA do homelab). Não editar.
# Também é o certificado PADRÃO: acessos pelo IP não enviam SNI e recebem este.
tls:
  certificates:
    - certFile: /traefik/certs/homelab-lan.crt
      keyFile: /traefik/certs/homelab-lan.key
  stores:
    default:
      defaultCertificate:
        certFile: /traefik/certs/homelab-lan.crt
        keyFile: /traefik/certs/homelab-lan.key

http:
  middlewares:
    # Porta 80 → HTTPS (rotas da LAN definidas em arquivo)
    homelab-redirect-https:
      redirectScheme:
        scheme: https
        permanent: true
    # Use nas rotas internas: traefik.http.routers.<nome>.middlewares=homelab-lan-only@file
    homelab-lan-only:
      ipAllowList:
        sourceRange:
          - 127.0.0.1/32
          - 10.0.0.0/8
          - 172.16.0.0/12
          - 192.168.0.0/16
          - 100.64.0.0/10
YAML
  log "Instalado no Traefik do Coolify (recarrega sozinho): $COOLIFY_PROXY/dynamic/homelab-lan.yaml"
}

days_left() {
  local end; end="$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)"
  echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}

cmd_renew() {
  have_ca || { echo "Sem CA — nada a renovar"; return 0; }
  if [[ ! -s "$CA_DIR/lan.crt" ]]; then cmd_issue; return; fi
  local left ip; left="$(days_left "$CA_DIR/lan.crt")"; ip="$(lan_ip)"
  if (( left < RENEW_BEFORE_DAYS )); then
    log "Faltam $left dias — renovando"; cmd_issue
  elif ! openssl x509 -in "$CA_DIR/lan.crt" -noout -ext subjectAltName | grep -q "IP Address:${ip}\b"; then
    log "IP da LAN mudou para $ip — reemitindo"; cmd_issue
  else
    echo "Certificado válido por mais $left dias — nada a fazer"
    [[ -d "$COOLIFY_PROXY" && ! -f "$COOLIFY_PROXY/dynamic/homelab-lan.yaml" ]] && install_traefik
  fi
  return 0
}

cmd_export() {
  have_ca || die "Nenhuma CA"
  local out="${1:-$CA_DIR/homelab-root-ca.crt}"
  install -m 644 "$CA_DIR/root.crt" "$out"
  echo "Certificado raiz: $out"
  echo "SHA-256: $(fingerprint "$CA_DIR/root.crt")"
  echo "No Mac:  scp $(logname 2>/dev/null || echo eduardo)@$(lan_host):$out ."
  echo "         sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $(basename "$out")"
}

cmd_status() {
  if have_ca; then
    echo "CA ............ $CA_DIR/root.crt"
    echo "  SHA-256 ..... $(fingerprint "$CA_DIR/root.crt")"
    echo "  validade .... $(openssl x509 -in "$CA_DIR/root.crt" -noout -enddate | cut -d= -f2)"
  else
    echo "CA ............ não configurada (import-caddy ou init)"
  fi
  if [[ -s "$CA_DIR/lan.crt" ]]; then
    echo "Certificado ... $(openssl x509 -in "$CA_DIR/lan.crt" -noout -ext subjectAltName | tail -1 | xargs)"
    echo "  expira em ... $(days_left "$CA_DIR/lan.crt") dias"
  else
    echo "Certificado ... não emitido (issue)"
  fi
  if [[ -f "$COOLIFY_PROXY/dynamic/homelab-lan.yaml" ]]; then
    echo "Traefik ....... configurado ($COOLIFY_PROXY/dynamic/homelab-lan.yaml)"
  else
    echo "Traefik ....... não configurado"
  fi
}

case "${1:-status}" in
  status)       cmd_status ;;
  init)         cmd_init ;;
  import-caddy) shift; cmd_import_caddy "${1:-}" ;;
  issue)        shift; cmd_issue "$@" ;;
  renew)        cmd_renew ;;
  export)       shift; cmd_export "${1:-}" ;;
  *) die "Uso: sudo $0 [status|import-caddy [volume]|init|issue [nomes]|renew|export [arquivo]]" ;;
esac
