#!/usr/bin/env bash
# Painéis do homelab — logs, tráfego, disponibilidade e logs estruturados das aplicações.
# Acessíveis só pela LAN/Tailscale, pelo proxy (HTTPS com a CA do homelab), cada um numa porta:
#
#   Logs ........ Dozzle        — logs de todos os containers, ao vivo        (padrão :9443)
#   Tráfego ..... GoAccess      — requisições por rota, status, IPs, páginas  (padrão :9444)
#   Status ...... Uptime Kuma   — monitora domínios/portas e envia alertas    (padrão :9445)
#   Seq ......... Seq           — logs estruturados (Serilog) das apps .NET   (padrão :9446)
#
#   sudo monitor.sh                 # status e endereços
#   sudo monitor.sh apply           # gera o compose a partir de monitor.conf e sobe/atualiza
#   sudo monitor.sh credenciais     # usuário e senha dos painéis
#   sudo monitor.sh remove          # para os painéis (dados preservados) e fecha as portas
#
# Configuração: $MONITOR_DIR/monitor.conf (liga/desliga cada painel e define as portas).
set -Eeuo pipefail
# shellcheck source=/dev/null
[[ -r "${HOMELAB_CONF:-/etc/homelab.conf}" ]] && . "${HOMELAB_CONF:-/etc/homelab.conf}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
PROXY_DIR="${PROXY_DIR:-$HOMELAB_DIR/proxy}"
MONITOR_DIR="${MONITOR_DIR:-$HOMELAB_DIR/monitor}"
CONF="$MONITOR_DIR/monitor.conf"
SECRETS="$MONITOR_DIR/.env"
COMPOSE="$MONITOR_DIR/docker-compose.yml"
PROXY_SH="$HOMELAB_DIR/scripts/proxy.sh"
PROXY_CONF="$PROXY_DIR/proxy.conf"

log()  { echo "==> $*"; }
ok()   { echo "  ✔ $*"; }
warn() { echo "  ! $*" >&2; }
die()  { echo "✘ $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo $0 $*"

DEFAULT_CONF='# Painéis do homelab — gerenciado por monitor.sh (edite e rode: sudo monitor.sh apply)
DOZZLE="true"           # logs dos containers
DOZZLE_PORT="9443"
GOACCESS="true"         # tráfego (lê o log de acesso do proxy)
GOACCESS_PORT="9444"
GOACCESS_INTERVAL="60"  # segundos entre atualizações do relatório
UPTIME_KUMA="true"      # disponibilidade e alertas
UPTIME_KUMA_PORT="9445"
SEQ="true"              # logs estruturados das apps (.NET/Serilog → http://seq:5341)
SEQ_PORT="9446"
SEQ_MEMORY="1g"         # limite de memória do Seq
# Imagens
DOZZLE_IMAGE="amir20/dozzle:latest"
GOACCESS_IMAGE="allinurl/goaccess:latest"
WEB_IMAGE="nginx:alpine"
UPTIME_KUMA_IMAGE="louislam/uptime-kuma:2"
SEQ_IMAGE="datalust/seq:latest"'

# Formato do log de acesso do Traefik (CLF) para o GoAccess:
#   IP - user [data] "requisição" status bytes "referer" "user-agent" nº "router" "servidor" duração
GOACCESS_LOG_FORMAT='%h %^[%d:%t %^] "%r" %s %b "%R" "%u" %^ "%v" "%^" %Lms'

load_conf() {
  install -d -m 755 "$MONITOR_DIR"
  [[ -f "$CONF" ]] || { printf '%s\n' "$DEFAULT_CONF" > "$CONF"; chmod 644 "$CONF"; }
  # shellcheck source=/dev/null
  . "$CONF"
  DOZZLE="${DOZZLE:-true}"; DOZZLE_PORT="${DOZZLE_PORT:-9443}"
  GOACCESS="${GOACCESS:-true}"; GOACCESS_PORT="${GOACCESS_PORT:-9444}"; GOACCESS_INTERVAL="${GOACCESS_INTERVAL:-60}"
  UPTIME_KUMA="${UPTIME_KUMA:-true}"; UPTIME_KUMA_PORT="${UPTIME_KUMA_PORT:-9445}"
  SEQ="${SEQ:-true}"; SEQ_PORT="${SEQ_PORT:-9446}"; SEQ_MEMORY="${SEQ_MEMORY:-1g}"
  DOZZLE_IMAGE="${DOZZLE_IMAGE:-amir20/dozzle:latest}"
  GOACCESS_IMAGE="${GOACCESS_IMAGE:-allinurl/goaccess:latest}"
  WEB_IMAGE="${WEB_IMAGE:-nginx:alpine}"
  UPTIME_KUMA_IMAGE="${UPTIME_KUMA_IMAGE:-louislam/uptime-kuma:2}"
  SEQ_IMAGE="${SEQ_IMAGE:-datalust/seq:latest}"
  PROXY_NETWORK="proxy"
  # shellcheck source=/dev/null
  [[ -r "$PROXY_CONF" ]] && PROXY_NETWORK="$(. "$PROXY_CONF"; echo "${PROXY_NETWORK:-proxy}")"
}

load_secrets() {
  if [[ ! -f "$SECRETS" ]]; then
    umask 077
    cat > "$SECRETS" <<EOF
# Credenciais dos painéis — gerado por monitor.sh (NÃO versionar)
MONITOR_USER=admin
MONITOR_EMAIL=admin@homelab.local
MONITOR_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)
EOF
    chmod 600 "$SECRETS"
  fi
  # shellcheck source=/dev/null
  . "$SECRETS"
}

lan_host() { echo "$(hostname).local"; }
lan_ip()   { hostname -I | awk '{print $1}'; }

# painel => "nome-do-entrypoint porta"
panels() {
  [[ "$DOZZLE" == true ]]      && echo "painel-logs $DOZZLE_PORT"
  [[ "$GOACCESS" == true ]]    && echo "painel-trafego $GOACCESS_PORT"
  [[ "$UPTIME_KUMA" == true ]] && echo "painel-status $UPTIME_KUMA_PORT"
  [[ "$SEQ" == true ]]         && echo "painel-seq $SEQ_PORT"
  return 0
}

# ---------------------------------------------------------------- proxy
# Ajusta, numa só aplicação, as portas dos painéis no proxy (entrypoints painel-*) e liga o log de acesso.
sync_proxy() {
  [[ -x "$PROXY_SH" && -f "$PROXY_CONF" ]] || die "Proxy do homelab não instalado (sudo $PROXY_SH apply)"
  local current want ep name port tmp changed=false
  # shellcheck source=/dev/null
  current="$(. "$PROXY_CONF"; echo "${PROXY_ENTRYPOINTS:-}")"
  want=""
  for ep in $current; do [[ "${ep%%=*}" == painel-* ]] || want+="${want:+ }$ep"; done
  while read -r name port; do [[ -n "$name" ]] && want+="${want:+ }$name=$port"; done < <(panels)
  cp "$PROXY_CONF" "$PROXY_CONF.monitor-prev"
  tmp="$(mktemp)"
  awk -v v="$want" 'BEGIN{FS=OFS="="; done=0}
       $1=="PROXY_ENTRYPOINTS"{print "PROXY_ENTRYPOINTS=\"" v "\""; done=1; next} {print}
       END{if(!done) print "PROXY_ENTRYPOINTS=\"" v "\""}' "$PROXY_CONF" > "$tmp"
  if grep -q '^ACCESS_LOG=' "$tmp"; then sed -i 's/^ACCESS_LOG=.*/ACCESS_LOG="true"/' "$tmp"; else echo 'ACCESS_LOG="true"' >> "$tmp"; fi
  cmp -s "$tmp" "$PROXY_CONF" || changed=true
  install -m 644 "$tmp" "$PROXY_CONF"; rm -f "$tmp"
  if $changed || ! docker ps --format '{{.Names}}' | grep -qx traefik; then
    log "Atualizando o proxy (portas dos painéis e log de acesso)"
    if ! "$PROXY_SH" apply; then
      install -m 644 "$PROXY_CONF.monitor-prev" "$PROXY_CONF"
      die "O proxy não aceitou as portas dos painéis — proxy.conf restaurado (porta em uso?)"
    fi
  fi
  rm -f "$PROXY_CONF.monitor-prev"
}

# ---------------------------------------------------------------- compose
labels() {   # labels NOME PORTA_INTERNA [middlewares extras]
  local n="$1" p="$2" mw="homelab-lan-only@file${3:+,$3}"
  cat <<EOF
    labels:
      - traefik.enable=true
      - traefik.docker.network=${PROXY_NETWORK}
      - traefik.http.routers.${n}.entrypoints=${n}
      - traefik.http.routers.${n}.rule=PathPrefix(\`/\`)
      - traefik.http.routers.${n}.tls=true
      - traefik.http.routers.${n}.middlewares=${mw}
      - traefik.http.routers.${n}.service=${n}
      - traefik.http.services.${n}.loadbalancer.server.port=${p}
EOF
}

GOACCESS_CHANGED=false
write_goaccess_runner() {
  install -d -m 755 "$MONITOR_DIR/goaccess" "$MONITOR_DIR/goaccess/db" "$MONITOR_DIR/goaccess/report"
  local f="$MONITOR_DIR/goaccess/run.sh" before=""
  [[ -f "$f" ]] && before="$(sha256sum "$f")"
  cat > "$f" <<EOF
#!/bin/sh
# Gerado por monitor.sh — atualiza o relatório de tráfego a cada ${GOACCESS_INTERVAL}s.
# --persist/--restore: histórico guardado em /data (não duplica linhas e sobrevive à rotação do log).
while :; do
  if [ -s /logs/access.log ]; then
    goaccess /logs/access.log --log-format='${GOACCESS_LOG_FORMAT}' \\
      --date-format=%d/%b/%Y --time-format=%T \\
      --persist --restore --db-path=/data \\
      --html-report-title='Tráfego — $(hostname)' --no-query-string \\
      -o /report/index.tmp.html >/dev/null 2>&1 \\
    && sed -i 's#<head>#<head><meta http-equiv="refresh" content="${GOACCESS_INTERVAL}">#' /report/index.tmp.html \\
    && mv /report/index.tmp.html /report/index.html
  elif [ ! -s /report/index.html ]; then
    echo '<!doctype html><meta http-equiv="refresh" content="30"><p>Aguardando tráfego no proxy…</p>' > /report/index.html
  fi
  sleep ${GOACCESS_INTERVAL}
done
EOF
  chmod 755 "$f"
  [[ "$(sha256sum "$f")" == "$before" ]] || GOACCESS_CHANGED=true
}

ensure_dozzle_users() {
  local f="$MONITOR_DIR/dozzle/users.yml"
  install -d -m 700 "$MONITOR_DIR/dozzle"
  [[ -s "$f" ]] && return 0
  log "Criando o usuário do painel de logs (Dozzle)"
  docker run --rm "$DOZZLE_IMAGE" generate "$MONITOR_USER" --password "$MONITOR_PASSWORD" \
    --email "$MONITOR_EMAIL" --name "Admin" > "$f.tmp" 2>/dev/null || true
  grep -q 'password:' "$f.tmp" 2>/dev/null || { rm -f "$f.tmp"; die "Não foi possível gerar o usuário do Dozzle (imagem $DOZZLE_IMAGE)"; }
  mv "$f.tmp" "$f"; chmod 600 "$f"
}

basic_auth_label() {   # middleware de senha (GoAccess não tem login próprio)
  local hash
  hash="$(openssl passwd -apr1 "$MONITOR_PASSWORD")"
  # no compose, "$" precisa ser escrito "$$"
  echo "      - traefik.http.middlewares.painel-senha.basicauth.users=${MONITOR_USER}:${hash//\$/\$\$}"
}

generate_compose() {
  local out="$1"
  {
    echo "# Gerado por monitor.sh — NÃO edite. Configure $CONF e rode: sudo monitor.sh apply"
    echo "name: homelab-monitor"
    echo "services:"
    if [[ "$DOZZLE" == true ]]; then
      cat <<EOF
  dozzle:
    image: ${DOZZLE_IMAGE}
    container_name: dozzle
    restart: unless-stopped
    environment:
      DOZZLE_AUTH_PROVIDER: simple
      DOZZLE_NO_ANALYTICS: "true"
      DOZZLE_HOSTNAME: "$(hostname)"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./dozzle:/data
    networks: [${PROXY_NETWORK}]
EOF
      labels painel-logs 8080
    fi
    if [[ "$GOACCESS" == true ]]; then
      cat <<EOF
  goaccess:
    image: ${GOACCESS_IMAGE}
    container_name: goaccess
    restart: unless-stopped
    entrypoint: ["/bin/sh", "/run.sh"]
    volumes:
      - ./goaccess/run.sh:/run.sh:ro
      - ${PROXY_DIR}/logs:/logs:ro
      - ./goaccess/db:/data
      - ./goaccess/report:/report
    network_mode: none
  goaccess-web:
    image: ${WEB_IMAGE}
    container_name: goaccess-web
    restart: unless-stopped
    volumes:
      - ./goaccess/report:/usr/share/nginx/html:ro
    networks: [${PROXY_NETWORK}]
EOF
      labels painel-trafego 80 painel-senha
      basic_auth_label
    fi
    if [[ "$UPTIME_KUMA" == true ]]; then
      cat <<EOF
  uptime-kuma:
    image: ${UPTIME_KUMA_IMAGE}
    container_name: uptime-kuma
    restart: unless-stopped
    volumes:
      - ./uptime-kuma:/app/data
    networks: [${PROXY_NETWORK}]
EOF
      labels painel-status 3001
    fi
    if [[ "$SEQ" == true ]]; then
      cat <<EOF
  seq:
    image: ${SEQ_IMAGE}
    container_name: seq
    restart: unless-stopped
    mem_limit: ${SEQ_MEMORY}
    environment:
      ACCEPT_EULA: "Y"
      SEQ_FIRSTRUN_ADMINPASSWORD: \${MONITOR_PASSWORD}
      SEQ_CACHE_SYSTEMRAMTARGET: "0.1"
    volumes:
      - ./seq:/data
    networks: [${PROXY_NETWORK}]
EOF
      labels painel-seq 80
    fi
    echo "networks:"
    echo "  ${PROXY_NETWORK}:"
    echo "    name: ${PROXY_NETWORK}"
    echo "    external: true"
  } > "$out"
}

cmd_apply() {
  load_conf; load_secrets
  if [[ -z "$(panels)" ]]; then
    warn "Todos os painéis desligados em $CONF"; cmd_remove; return 0
  fi
  sync_proxy
  [[ "$DOZZLE" == true ]] && ensure_dozzle_users
  [[ "$GOACCESS" == true ]] && write_goaccess_runner
  [[ "$UPTIME_KUMA" == true ]] && install -d -m 700 "$MONITOR_DIR/uptime-kuma"
  [[ "$SEQ" == true ]] && install -d -m 700 "$MONITOR_DIR/seq"
  local tmp; tmp="$(mktemp)"; generate_compose "$tmp"
  install -m 600 "$tmp" "$COMPOSE"; rm -f "$tmp"
  docker compose --project-directory "$MONITOR_DIR" -f "$COMPOSE" config --quiet || die "Compose dos painéis inválido"
  log "Subindo os painéis"
  docker compose --project-directory "$MONITOR_DIR" -f "$COMPOSE" up -d --remove-orphans
  # o script do GoAccess é montado como arquivo: mudou → reinicia para valer
  if $GOACCESS_CHANGED && docker ps --format '{{.Names}}' | grep -qx goaccess; then docker restart goaccess >/dev/null; fi
  cmd_status
  echo
  echo "Usuário e senha: sudo $0 credenciais"
  [[ "$UPTIME_KUMA" == true && ! -s "$MONITOR_DIR/uptime-kuma/kuma.db" ]] && \
    echo "Uptime Kuma: no primeiro acesso, crie o usuário administrador (só a LAN alcança o painel)."
  return 0
}

cmd_status() {
  load_conf
  local host ip name port c s label LC_ALL=C.UTF-8   # ${#label} conta caracteres (acentos)
  host="$(lan_host)"; ip="$(lan_ip)"
  echo "Painéis (só LAN/Tailscale):"
  while read -r name port; do
    [[ -n "$name" ]] || continue
    case "$name" in
      painel-logs)    c=dozzle;       label="Logs (Dozzle)" ;;
      painel-trafego) c=goaccess-web; label="Tráfego (GoAccess)" ;;
      painel-status)  c=uptime-kuma;  label="Status (Uptime Kuma)" ;;
      painel-seq)     c=seq;          label="Seq (logs .NET)" ;;
    esac
    s="$(docker inspect -f '{{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}' "$c" 2>/dev/null || echo 'parado')"
    printf '  %s%*s https://%s:%s  |  https://%s:%s   [%s]\n' "$label" $((22 - ${#label})) '' "$host" "$port" "$ip" "$port" "$s"
  done < <(panels)
  [[ "$SEQ" == true ]] && echo "  Apps .NET → Seq: WriteTo.Seq(\"http://seq:5341\")  (serviço na rede ${PROXY_NETWORK})"
  return 0
}

cmd_credentials() {
  load_conf; load_secrets
  echo "Usuário ... $MONITOR_USER   (Dozzle e Tráfego)"
  echo "Senha ..... $MONITOR_PASSWORD"
  echo "Seq ....... admin / mesma senha (troca obrigatória no primeiro acesso)"
  echo "Uptime Kuma: usuário criado por você no primeiro acesso"
  echo "Arquivo ... $SECRETS"
}

cmd_remove() {
  load_conf
  [[ -f "$COMPOSE" ]] && docker compose --project-directory "$MONITOR_DIR" -f "$COMPOSE" down --remove-orphans || true
  if [[ -f "$PROXY_CONF" ]] && grep -q 'painel-' "$PROXY_CONF"; then
    local current want ep
    # shellcheck source=/dev/null
    current="$(. "$PROXY_CONF"; echo "${PROXY_ENTRYPOINTS:-}")"; want=""
    for ep in $current; do [[ "${ep%%=*}" == painel-* ]] || want+="${want:+ }$ep"; done
    sed -i "s/^PROXY_ENTRYPOINTS=.*/PROXY_ENTRYPOINTS=\"$want\"/" "$PROXY_CONF"
    "$PROXY_SH" apply >/dev/null
  fi
  ok "Painéis parados e portas fechadas (dados preservados em $MONITOR_DIR)"
}

case "${1:-status}" in
  status)              cmd_status ;;
  apply|up)            cmd_apply ;;
  credenciais|senha)   cmd_credentials ;;
  remove|down)         cmd_remove ;;
  -h|--help)           sed -n '2,/^set -Eeuo/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  *) die "Comando desconhecido: $1 (veja: $0 --help)" ;;
esac
