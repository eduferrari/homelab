#!/usr/bin/env bash
# Painéis do homelab — logs, tráfego, disponibilidade e logs estruturados das aplicações.
# Acessíveis só pela LAN/Tailscale, pelo proxy (HTTPS com a CA do homelab), cada um numa porta:
#
#   Geral ....... painel.sh     — tudo numa página: alertas, atalhos, servidor,
#                                 containers, domínios, tráfego 24 h e backup   (padrão :9440)
#   Logs ........ Dozzle        — logs de todos os containers, ao vivo        (padrão :9443)
#   Tráfego ..... GoAccess      — requisições por rota, status, IPs, páginas  (padrão :9444)
#   Status ...... Uptime Kuma   — monitora domínios/portas e envia alertas    (padrão :9445)
#   Seq ......... Seq           — logs estruturados (Serilog) das apps .NET   (padrão :9446)
#   Adminer, RedisInsight e RabbitMQ (stack de dados) também passam pelo proxy:  :9447, :9448, :9449
#
# O log do backup (/var/log/homelab/backup.log) aparece no Dozzle como o container "backup-log".
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
PAINEL="true"           # painel geral (uma página com tudo, atualizada a cada minuto)
PAINEL_PORT="9440"
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
BACKUP_LOG="true"       # mostra o log do backup no Dozzle (container backup-log)
INFRA_UIS="true"        # Adminer, RedisInsight e RabbitMQ (stack de dados) em HTTPS pelo proxy
ADMINER_UI_PORT="9447"
REDIS_UI_PORT="9448"
RABBITMQ_UI_HTTPS_PORT="9449"
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
  # monitor.conf de versões anteriores: acrescenta as opções novas (com o valor padrão)
  local key added=""
  for key in PAINEL PAINEL_PORT BACKUP_LOG INFRA_UIS ADMINER_UI_PORT REDIS_UI_PORT RABBITMQ_UI_HTTPS_PORT; do
    grep -q "^${key}=" "$CONF" || added+="$(grep "^${key}=" <<<"$DEFAULT_CONF")"$'\n'
  done
  [[ -z "$added" ]] || printf '# Opções novas (monitor.sh)\n%s' "$added" >> "$CONF"
  # shellcheck source=/dev/null
  . "$CONF"
  PAINEL="${PAINEL:-true}"; PAINEL_PORT="${PAINEL_PORT:-9440}"
  DOZZLE="${DOZZLE:-true}"; DOZZLE_PORT="${DOZZLE_PORT:-9443}"
  GOACCESS="${GOACCESS:-true}"; GOACCESS_PORT="${GOACCESS_PORT:-9444}"; GOACCESS_INTERVAL="${GOACCESS_INTERVAL:-60}"
  UPTIME_KUMA="${UPTIME_KUMA:-true}"; UPTIME_KUMA_PORT="${UPTIME_KUMA_PORT:-9445}"
  SEQ="${SEQ:-true}"; SEQ_PORT="${SEQ_PORT:-9446}"; SEQ_MEMORY="${SEQ_MEMORY:-1g}"
  BACKUP_LOG="${BACKUP_LOG:-true}"
  INFRA_UIS="${INFRA_UIS:-true}"; ADMINER_UI_PORT="${ADMINER_UI_PORT:-9447}"
  REDIS_UI_PORT="${REDIS_UI_PORT:-9448}"; RABBITMQ_UI_HTTPS_PORT="${RABBITMQ_UI_HTTPS_PORT:-9449}"
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
  ensure_auth_hash
}

# Hash da senha (basic auth do proxy) guardado no .env: gerado uma vez e refeito só se a senha
# mudar — assim o middleware não muda a cada apply.
ensure_auth_hash() {
  local salt
  # shellcheck disable=SC2016  # prefixo literal do hash
  if [[ "${MONITOR_AUTH_HASH:-}" == '$apr1$'* ]]; then
    salt="$(cut -d'$' -f3 <<<"$MONITOR_AUTH_HASH")"
    [[ "$(openssl passwd -apr1 -salt "$salt" "$MONITOR_PASSWORD")" == "$MONITOR_AUTH_HASH" ]] && return 0
  fi
  MONITOR_AUTH_HASH="$(openssl passwd -apr1 "$MONITOR_PASSWORD")"
  sed -i '/^MONITOR_AUTH_HASH=/d' "$SECRETS"
  printf "MONITOR_AUTH_HASH='%s'\n" "$MONITOR_AUTH_HASH" >> "$SECRETS"
}

lan_host() { echo "$(hostname).local"; }
lan_ip()   { hostname -I | awk '{print $1}'; }

# painel => "nome-do-entrypoint porta"
panels() {
  [[ "$PAINEL" == true ]]      && echo "painel-geral $PAINEL_PORT"
  [[ "$DOZZLE" == true ]]      && echo "painel-logs $DOZZLE_PORT"
  [[ "$GOACCESS" == true ]]    && echo "painel-trafego $GOACCESS_PORT"
  [[ "$UPTIME_KUMA" == true ]] && echo "painel-status $UPTIME_KUMA_PORT"
  [[ "$SEQ" == true ]]         && echo "painel-seq $SEQ_PORT"
  if [[ "$INFRA_UIS" == true ]]; then   # containers da stack de dados (labels no compose da infra)
    echo "painel-adminer $ADMINER_UI_PORT"; echo "painel-redis $REDIS_UI_PORT"; echo "painel-rabbitmq $RABBITMQ_UI_HTTPS_PORT"
  fi
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

# Middleware de senha (painel geral e GoAccess não têm login próprio), no provedor de arquivo
# do proxy: painel-senha@file.
AUTH_FILE="$PROXY_DIR/dynamic/homelab-monitor.yaml"
write_auth_middleware() {
  local tmp; tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Gerado por monitor.sh — senha dos painéis (sudo monitor.sh credenciais)
http:
  middlewares:
    painel-senha:
      basicAuth:
        realm: homelab
        users:
          - '${MONITOR_USER}:${MONITOR_AUTH_HASH}'
EOF
  if ! cmp -s "$tmp" "$AUTH_FILE"; then install -m 600 "$tmp" "$AUTH_FILE"; fi
  rm -f "$tmp"
}

# Gerador do painel geral: roda a cada minuto (systemd), como root (lê Docker, acme.json, backups).
install_painel_timer() {
  cat > /etc/systemd/system/homelab-painel.service <<EOF
[Unit]
Description=Gera o painel geral do homelab
After=docker.service

[Service]
Type=oneshot
ExecStart=${HOMELAB_DIR}/scripts/painel.sh
Nice=10
EOF
  cat > /etc/systemd/system/homelab-painel.timer <<'EOF'
[Unit]
Description=Atualiza o painel geral do homelab a cada minuto

[Timer]
OnCalendar=minutely
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable --now homelab-painel.timer >/dev/null 2>&1 || warn "Não foi possível ativar homelab-painel.timer"
}

remove_painel_timer() {
  [[ -f /etc/systemd/system/homelab-painel.timer ]] || return 0
  systemctl disable --now homelab-painel.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/homelab-painel.{service,timer}
  systemctl daemon-reload 2>/dev/null || true
}

generate_compose() {
  local out="$1"
  {
    echo "# Gerado por monitor.sh — NÃO edite. Configure $CONF e rode: sudo monitor.sh apply"
    echo "name: homelab-monitor"
    echo "services:"
    if [[ "$PAINEL" == true ]]; then
      cat <<EOF
  painel-web:
    image: ${WEB_IMAGE}
    container_name: painel
    restart: unless-stopped
    volumes:
      - ./painel:/usr/share/nginx/html:ro
    networks: [${PROXY_NETWORK}]
EOF
      labels painel-geral 80 painel-senha@file
    fi
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
      labels painel-trafego 80 painel-senha@file
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
    if [[ "$BACKUP_LOG" == true && "$DOZZLE" == true ]]; then
      cat <<EOF
  backup-log:
    # só repassa o log do backup para o Dozzle (container "backup-log")
    image: ${WEB_IMAGE}
    container_name: backup-log
    restart: unless-stopped
    init: true
    entrypoint: ["tail", "-n", "200", "-F", "/logs/backup.log"]
    volumes:
      - /var/log/homelab:/logs:ro
    network_mode: none
EOF
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
  write_auth_middleware
  [[ "$DOZZLE" == true ]] && ensure_dozzle_users
  [[ "$BACKUP_LOG" == true ]] && install -d -m 755 /var/log/homelab
  if [[ "$PAINEL" == true ]]; then
    install -d -m 755 "$MONITOR_DIR/painel"
    [[ -s "$MONITOR_DIR/painel/index.html" ]] || \
      echo '<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="10"><p>Gerando o painel…</p>' > "$MONITOR_DIR/painel/index.html"
  fi
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
  if [[ "$PAINEL" == true ]]; then
    install_painel_timer
    "$HOMELAB_DIR/scripts/painel.sh" || warn "Painel geral: falha ao gerar a página (sudo $HOMELAB_DIR/scripts/painel.sh)"
  else
    remove_painel_timer
  fi
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
      painel-geral)   c=painel;       label="Geral" ;;
      painel-logs)    c=dozzle;       label="Logs (Dozzle)" ;;
      painel-trafego) c=goaccess-web; label="Tráfego (GoAccess)" ;;
      painel-status)  c=uptime-kuma;  label="Status (Uptime Kuma)" ;;
      painel-seq)     c=seq;          label="Seq (logs .NET)" ;;
      painel-adminer) c=adminer;      label="Adminer (MySQL)" ;;
      painel-redis)   c=redisinsight; label="RedisInsight" ;;
      painel-rabbitmq) c=rabbitmq;    label="RabbitMQ" ;;
    esac
    s="$(docker inspect -f '{{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}' "$c" 2>/dev/null)" || s="não instalado"
    printf '  %s%*s https://%s:%s  |  https://%s:%s   [%s]\n' "$label" $((22 - ${#label})) '' "$host" "$port" "$ip" "$port" "$s"
  done < <(panels)
  [[ "$SEQ" == true ]] && echo "  Apps .NET → Seq: WriteTo.Seq(\"http://seq:5341\")  (serviço na rede ${PROXY_NETWORK})"
  return 0
}

cmd_credentials() {
  load_conf; load_secrets
  echo "Usuário ... $MONITOR_USER   (Geral, Logs e Tráfego)"
  echo "Senha ..... $MONITOR_PASSWORD"
  echo "Seq ....... admin / mesma senha (troca obrigatória no primeiro acesso)"
  echo "Uptime Kuma: usuário criado por você no primeiro acesso"
  echo "Arquivo ... $SECRETS"
}

cmd_remove() {
  load_conf
  [[ -f "$COMPOSE" ]] && docker compose --project-directory "$MONITOR_DIR" -f "$COMPOSE" down --remove-orphans || true
  remove_painel_timer
  rm -f "$AUTH_FILE"
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
