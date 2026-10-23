#!/usr/bin/env bash
# SonarQube (Community Build) no homelab — análise de qualidade e segurança do código dos projetos.
#
#   Painel ...... https://<host>:9450 (pelo proxy, só LAN/Tailscale)
#   Análise ..... http://127.0.0.1:9000 (só no próprio servidor: runner do GitHub Actions)
#
#   sudo sonarqube.sh                 # status e endereços
#   sudo sonarqube.sh apply           # instala/atualiza (compose em $SONAR_DIR, kernel, proxy)
#   sudo sonarqube.sh credenciais     # login inicial e onde ficam as senhas
#   sudo sonarqube.sh remove          # para o SonarQube e fecha a porta (dados preservados)
#
# Configuração: $SONAR_DIR/sonarqube.conf (porta, imagens, memória). Banco: PostgreSQL próprio
# (o SonarQube não aceita MySQL), com a senha em $SONAR_DIR/.env (600).
set -Eeuo pipefail
# shellcheck source=/dev/null
[[ -r "${HOMELAB_CONF:-/etc/homelab.conf}" ]] && . "${HOMELAB_CONF:-/etc/homelab.conf}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
PROXY_DIR="${PROXY_DIR:-$HOMELAB_DIR/proxy}"
SONAR_DIR="${SONAR_DIR:-$HOMELAB_DIR/sonarqube}"
CONF="$SONAR_DIR/sonarqube.conf"
SECRETS="$SONAR_DIR/.env"
COMPOSE="$SONAR_DIR/docker-compose.yml"
PROXY_SH="$HOMELAB_DIR/scripts/proxy.sh"
PROXY_CONF="$PROXY_DIR/proxy.conf"
SYSCTL_FILE=/etc/sysctl.d/99-sonarqube.conf
EP_NAME="sonar"            # entrypoint do proxy (fora do prefixo painel-*, que é do monitor.sh)

log()  { echo "==> $*"; }
ok()   { echo "  ✔ $*"; }
warn() { echo "  ! $*" >&2; }
die()  { echo "✘ $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo $0 $*"

DEFAULT_CONF='# SonarQube do homelab — gerenciado por sonarqube.sh (edite e rode: sudo sonarqube.sh apply)
SONAR_PORT="9450"             # painel HTTPS pelo proxy (só LAN/Tailscale)
SONAR_LOCAL_PORT="9000"       # análise pelo runner: http://127.0.0.1:<porta> (só no servidor)
SONAR_MEMORY="4g"             # limite de memória do SonarQube (web + compute engine + Elasticsearch)
SONAR_DB_MEMORY="1g"          # limite de memória do PostgreSQL
SONAR_IMAGE="sonarqube:community"
POSTGRES_IMAGE="postgres:17-alpine"'

load_conf() {
  install -d -m 755 "$SONAR_DIR"
  [[ -f "$CONF" ]] || { printf '%s\n' "$DEFAULT_CONF" > "$CONF"; chmod 644 "$CONF"; }
  # shellcheck source=/dev/null
  . "$CONF"
  SONAR_PORT="${SONAR_PORT:-9450}"; SONAR_LOCAL_PORT="${SONAR_LOCAL_PORT:-9000}"
  SONAR_MEMORY="${SONAR_MEMORY:-4g}"; SONAR_DB_MEMORY="${SONAR_DB_MEMORY:-1g}"
  SONAR_IMAGE="${SONAR_IMAGE:-sonarqube:community}"; POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:17-alpine}"
  PROXY_NETWORK="proxy"
  # shellcheck source=/dev/null
  [[ -r "$PROXY_CONF" ]] && PROXY_NETWORK="$(. "$PROXY_CONF"; echo "${PROXY_NETWORK:-proxy}")"
}

load_secrets() {
  if [[ ! -f "$SECRETS" ]]; then
    umask 077
    printf '# SonarQube — gerado por sonarqube.sh (NÃO versionar)\nSONAR_DB_PASSWORD=%s\n' \
      "$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-28)" > "$SECRETS"
    chmod 600 "$SECRETS"
  fi
}

# Elasticsearch interno do SonarQube exige estes limites do kernel (senão o container não sobe)
ensure_kernel() {
  cat > "$SYSCTL_FILE" <<'EOF'
# SonarQube (Elasticsearch interno) — gerado por sonarqube.sh
vm.max_map_count = 524288
fs.file-max = 131072
EOF
  if sysctl -q -p "$SYSCTL_FILE" >/dev/null 2>&1; then
    ok "Kernel: vm.max_map_count=$(sysctl -n vm.max_map_count)"
  else
    warn "Não foi possível aplicar $SYSCTL_FILE agora (vale no próximo boot)"
  fi
}

# Porta do painel no proxy (só altera o proxy se a porta mudou)
sync_proxy() {
  [[ -x "$PROXY_SH" && -f "$PROXY_CONF" ]] || die "Proxy do homelab não instalado (sudo $PROXY_SH apply)"
  local current
  # shellcheck source=/dev/null
  current="$(. "$PROXY_CONF"; echo " ${PROXY_ENTRYPOINTS:-} ")"
  if [[ "$current" != *" $EP_NAME=$SONAR_PORT "* ]]; then
    log "Abrindo a porta $SONAR_PORT no proxy"
    "$PROXY_SH" entrypoint add "$EP_NAME" "$SONAR_PORT" || die "O proxy não aceitou a porta $SONAR_PORT (em uso?)"
  fi
}

generate_compose() {
  cat <<EOF
# Gerado por sonarqube.sh — NÃO edite. Configure $CONF e rode: sudo sonarqube.sh apply
name: homelab-sonarqube
services:
  sonarqube-db:
    image: ${POSTGRES_IMAGE}
    container_name: sonarqube-db
    restart: unless-stopped
    mem_limit: ${SONAR_DB_MEMORY}
    environment:
      POSTGRES_USER: sonar
      POSTGRES_PASSWORD: \${SONAR_DB_PASSWORD}
      POSTGRES_DB: sonar
    volumes:
      - ./postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U sonar -d sonar"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks: [sonar]
  sonarqube:
    image: ${SONAR_IMAGE}
    container_name: sonarqube
    restart: unless-stopped
    mem_limit: ${SONAR_MEMORY}
    depends_on:
      sonarqube-db:
        condition: service_healthy
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://sonarqube-db:5432/sonar
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: \${SONAR_DB_PASSWORD}
      SONAR_TELEMETRY_ENABLE: "false"
    ulimits:
      nofile: { soft: 131072, hard: 131072 }
      nproc: 8192
    volumes:
      - ./data:/opt/sonarqube/data
      - ./extensions:/opt/sonarqube/extensions
      - ./logs:/opt/sonarqube/logs
    ports:
      - "127.0.0.1:${SONAR_LOCAL_PORT}:9000"   # análise pelo runner, só no próprio servidor
    networks: [sonar, ${PROXY_NETWORK}]
    labels:
      - traefik.enable=true
      - traefik.docker.network=${PROXY_NETWORK}
      - traefik.http.routers.${EP_NAME}.entrypoints=${EP_NAME}
      - traefik.http.routers.${EP_NAME}.rule=PathPrefix(\`/\`)
      - traefik.http.routers.${EP_NAME}.tls=true
      - traefik.http.routers.${EP_NAME}.middlewares=homelab-lan-only@file
      - traefik.http.routers.${EP_NAME}.service=${EP_NAME}
      - traefik.http.services.${EP_NAME}.loadbalancer.server.port=9000
networks:
  sonar:
    name: homelab-sonar
  ${PROXY_NETWORK}:
    name: ${PROXY_NETWORK}
    external: true
EOF
}

compose() { docker compose --project-directory "$SONAR_DIR" -f "$COMPOSE" --env-file "$SECRETS" "$@"; }

cmd_apply() {
  load_conf; load_secrets
  ensure_kernel
  sync_proxy
  # o SonarQube roda como uid 1000; o PostgreSQL cuida da própria pasta
  install -d -m 750 -o 1000 -g 1000 "$SONAR_DIR/data" "$SONAR_DIR/extensions" "$SONAR_DIR/logs"
  install -d -m 700 "$SONAR_DIR/postgres"
  local tmp; tmp="$(mktemp)"; generate_compose > "$tmp"
  install -m 600 "$tmp" "$COMPOSE"; rm -f "$tmp"
  compose config --quiet || die "Compose do SonarQube inválido"
  log "Subindo o SonarQube (a primeira subida leva 1–3 minutos)"
  compose up -d --remove-orphans
  wait_ready || warn "SonarQube ainda iniciando — acompanhe: docker logs -f sonarqube"
  cmd_status
  echo
  echo "Primeiro acesso: usuário admin / senha admin (o SonarQube pede a troca). Detalhes: sudo $0 credenciais"
}

wait_ready() {
  local i st
  for (( i = 0; i < 60; i++ )); do
    st="$(curl -fsS -m 5 "http://127.0.0.1:${SONAR_LOCAL_PORT}/api/system/status" 2>/dev/null | grep -o '"status":"[A-Z_]*"' | cut -d'"' -f4 || true)"
    [[ "$st" == "UP" ]] && { ok "SonarQube no ar"; return 0; }
    sleep 5
  done
  return 1
}

cmd_status() {
  load_conf
  local st host ip
  host="$(hostname).local"; ip="$(hostname -I | awk '{print $1}')"
  st="$(docker inspect -f '{{.State.Status}}' sonarqube 2>/dev/null)" || st="não instalado"
  local api; api="$(curl -fsS -m 5 "http://127.0.0.1:${SONAR_LOCAL_PORT}/api/system/status" 2>/dev/null | grep -o '"status":"[A-Z_]*"' | cut -d'"' -f4 || true)"
  echo "SonarQube ..... ${st}${api:+ ($api)}"
  echo "Painel ........ https://${host}:${SONAR_PORT}  |  https://${ip}:${SONAR_PORT}   (só LAN/Tailscale)"
  echo "Análise (CI) .. http://127.0.0.1:${SONAR_LOCAL_PORT}   (runner do GitHub Actions, no próprio servidor)"
}

cmd_credentials() {
  load_conf
  echo "Painel ......... usuário admin / senha admin no primeiro acesso (troca obrigatória)"
  echo "Token de análise: My Account → Security → Generate Token (tipo Global Analysis)"
  echo "                  → secret SONAR_TOKEN no repositório do projeto"
  echo "Banco (interno) . $SECRETS"
}

cmd_remove() {
  load_conf
  [[ -f "$COMPOSE" ]] && compose down --remove-orphans || true
  local eps=""
  # shellcheck source=/dev/null
  [[ -f "$PROXY_CONF" ]] && eps="$(. "$PROXY_CONF"; echo " ${PROXY_ENTRYPOINTS:-} ")"
  if [[ "$eps" == *" $EP_NAME="* ]]; then "$PROXY_SH" entrypoint remove "$EP_NAME" >/dev/null; fi
  ok "SonarQube parado e porta fechada (dados preservados em $SONAR_DIR; ajuste do kernel em $SYSCTL_FILE)"
}

case "${1:-status}" in
  status)            cmd_status ;;
  apply|up)          cmd_apply ;;
  credenciais|senha) cmd_credentials ;;
  remove|down)       cmd_remove ;;
  -h|--help)         sed -n '2,/^set -Eeuo/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  *) die "Comando desconhecido: $1 (veja: $0 --help)" ;;
esac
