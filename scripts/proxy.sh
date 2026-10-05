#!/usr/bin/env bash
# Proxy reverso do homelab (Traefik v3): HTTPS na LAN com a CA do homelab, domínios públicos com
# Let's Encrypt e rotas dos projetos por labels Docker. Substitui o Traefik que vinha com o Coolify.
#
#   sudo proxy.sh                          # status
#   sudo proxy.sh apply                    # gera o compose a partir de proxy.conf e sobe/atualiza
#   sudo proxy.sh entrypoint add NOME PORTA    # porta extra na LAN (ex.: pdv 8081)
#   sudo proxy.sh entrypoint remove NOME
#   sudo proxy.sh acme tls|http [EMAIL]    # desafio do Let's Encrypt (tls = só porta 443)
#   sudo proxy.sh image traefik:v3.7       # troca a versão do Traefik
#   sudo proxy.sh logs                     # últimos logs (erros e ACME)
#   sudo proxy.sh check                    # containers com rotas em rede que o proxy não alcança
#
# Migração de um homelab com Coolify (uma vez):
#   sudo proxy.sh migrate-coolify          # importa certificados/entrypoints, para o Coolify, sobe o proxy
#   sudo proxy.sh rollback-coolify         # desfaz (antes do remove)
#   sudo proxy.sh remove-coolify           # remove o Coolify de vez (backup antes)
#
# Configuração: $PROXY_DIR/proxy.conf (no servidor, não versionada). O compose é gerado — não edite.
set -Eeuo pipefail
# shellcheck source=/dev/null
[[ -r "${HOMELAB_CONF:-/etc/homelab.conf}" ]] && . "${HOMELAB_CONF:-/etc/homelab.conf}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
PROXY_DIR="${PROXY_DIR:-$HOMELAB_DIR/proxy}"
CONF="$PROXY_DIR/proxy.conf"
COMPOSE="$PROXY_DIR/docker-compose.yml"
CONTAINER="traefik"
COOLIFY_DIR="${COOLIFY_DIR:-/data/coolify}"
COOLIFY_PROXY="$COOLIFY_DIR/proxy"

log()  { echo "==> $*"; }
ok()   { echo "  ✔ $*"; }
warn() { echo "  ! $*" >&2; }
die()  { echo "✘ $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo $0 $*"
command -v docker >/dev/null || die "Docker não encontrado"

# ------------------------------------------------------------ configuração
DEFAULT_CONF='# Proxy do homelab — gerenciado por proxy.sh (edite e rode: sudo proxy.sh apply)
TRAEFIK_IMAGE="traefik:v3.7"
# Rede Docker do proxy: projetos entram nela (networks: [default, proxy]) com traefik.docker.network=proxy
PROXY_NETWORK="proxy"
# Redes extras às quais o proxy também se conecta (ex.: "coolify" de projetos migrados)
PROXY_EXTRA_NETWORKS=""
# Portas extras na LAN, "nome=porta" separados por espaço (labels: entrypoints=<nome>)
PROXY_ENTRYPOINTS=""
# Let'"'"'s Encrypt: tls (desafio TLS-ALPN, só porta 443) | http (desafio HTTP-01, porta 80)
ACME_CHALLENGE="tls"
ACME_EMAIL=""
LOG_LEVEL="INFO"'

load_conf() {
  install -d -m 755 "$PROXY_DIR" "$PROXY_DIR/dynamic" "$PROXY_DIR/certs"
  install -d -m 700 "$PROXY_DIR/acme"
  [[ -f "$CONF" ]] || { printf '%s\n' "$DEFAULT_CONF" > "$CONF"; chmod 644 "$CONF"; }
  # shellcheck source=/dev/null
  . "$CONF"
  TRAEFIK_IMAGE="${TRAEFIK_IMAGE:-traefik:v3.7}"
  PROXY_NETWORK="${PROXY_NETWORK:-proxy}"
  PROXY_EXTRA_NETWORKS="${PROXY_EXTRA_NETWORKS:-}"
  PROXY_ENTRYPOINTS="${PROXY_ENTRYPOINTS:-}"
  ACME_CHALLENGE="${ACME_CHALLENGE:-tls}"
  ACME_EMAIL="${ACME_EMAIL:-}"
  LOG_LEVEL="${LOG_LEVEL:-INFO}"
}

set_conf() {   # set_conf CHAVE VALOR
  local tmp; tmp="$(mktemp)"
  if grep -q "^$1=" "$CONF"; then
    awk -v k="$1" -v v="$2" 'BEGIN{FS=OFS="="} $1==k{print k "=\"" v "\""; next} {print}' "$CONF" > "$tmp"
  else
    cat "$CONF" > "$tmp"; echo "$1=\"$2\"" >> "$tmp"
  fi
  install -m 644 "$tmp" "$CONF"; rm -f "$tmp"
}

valid_ep_name() { [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,40}$ && "$1" != "http" && "$1" != "https" && "$1" != "traefik" ]]; }

# ---------------------------------------------------------------- compose
ensure_networks() {
  docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1 \
    || { docker network create "$PROXY_NETWORK" >/dev/null; ok "Rede $PROXY_NETWORK criada"; }
}

extra_networks_present() {   # só as redes extras que existem (compose falharia com rede inexistente)
  local n
  for n in $PROXY_EXTRA_NETWORKS; do
    [[ "$n" == "$PROXY_NETWORK" ]] && continue
    if docker network inspect "$n" >/dev/null 2>&1; then echo "$n"; else warn "Rede extra '$n' não existe — ignorada"; fi
  done
}

generate_compose() {
  local out="$1" ep name port nets n
  nets="$(extra_networks_present)"
  {
    echo "# Gerado por proxy.sh — NÃO edite. Configure $CONF e rode: sudo proxy.sh apply"
    echo "name: homelab-proxy"
    echo "services:"
    echo "  traefik:"
    echo "    image: ${TRAEFIK_IMAGE}"
    echo "    container_name: ${CONTAINER}"
    echo "    restart: unless-stopped"
    echo "    security_opt: [\"no-new-privileges:true\"]"
    echo "    command:"
    echo "      - --ping=true"
    echo "      - --log.level=${LOG_LEVEL}"
    echo "      - --entrypoints.http.address=:80"
    echo "      - --entrypoints.https.address=:443"
    for ep in $PROXY_ENTRYPOINTS; do
      name="${ep%%=*}"; port="${ep##*=}"
      echo "      - --entrypoints.${name}.address=:${port}"
    done
    echo "      - --providers.docker=true"
    echo "      - --providers.docker.exposedbydefault=false"
    echo "      - --providers.docker.network=${PROXY_NETWORK}"
    echo "      - --providers.file.directory=/dynamic"
    echo "      - --providers.file.watch=true"
    if [[ "$ACME_CHALLENGE" == "http" ]]; then
      echo "      - --certificatesresolvers.letsencrypt.acme.httpchallenge=true"
      echo "      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=http"
    else
      echo "      - --certificatesresolvers.letsencrypt.acme.tlschallenge=true"
    fi
    [[ -n "$ACME_EMAIL" ]] && echo "      - --certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL}"
    echo "      - --certificatesresolvers.letsencrypt.acme.storage=/acme/acme.json"
    echo "    ports:"
    echo "      - \"80:80\""
    echo "      - \"443:443\""
    for ep in $PROXY_ENTRYPOINTS; do
      port="${ep##*=}"; echo "      - \"${port}:${port}\""
    done
    echo "    volumes:"
    echo "      - /var/run/docker.sock:/var/run/docker.sock:ro"
    echo "      - ./dynamic:/dynamic:ro"
    echo "      - ./certs:/certs:ro"
    echo "      - ./acme:/acme"
    echo "    networks:"
    echo "      - ${PROXY_NETWORK}"
    for n in $nets; do echo "      - ${n}"; done
    echo "    healthcheck:"
    echo "      test: [\"CMD\", \"traefik\", \"healthcheck\", \"--ping\"]"
    echo "      interval: 10s"
    echo "      timeout: 5s"
    echo "      retries: 3"
    echo "      start_period: 10s"
    echo "networks:"
    echo "  ${PROXY_NETWORK}:"
    echo "    name: ${PROXY_NETWORK}"
    echo "    external: true"
    for n in $nets; do
      echo "  ${n}:"
      echo "    name: ${n}"
      echo "    external: true"
    done
  } > "$out"
}

validate_conf() {
  local ep name port seen=" 80 443 "
  [[ "$ACME_CHALLENGE" =~ ^(tls|http)$ ]] || die "ACME_CHALLENGE deve ser tls ou http"
  for ep in $PROXY_ENTRYPOINTS; do
    [[ "$ep" == *=* ]] || die "Entrypoint inválido em PROXY_ENTRYPOINTS: '$ep' (use nome=porta)"
    name="${ep%%=*}"; port="${ep##*=}"
    valid_ep_name "$name" || die "Nome de entrypoint inválido: '$name'"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then die "Porta inválida: '$port'"; fi
    [[ "$seen" != *" $port "* ]] || die "Porta $port repetida"
    seen+="$port "
  done
}

wait_healthy() {
  local s
  for _ in $(seq 1 30); do
    s="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER" 2>/dev/null || echo missing)"
    [[ "$s" == "healthy" ]] && return 0
    sleep 2
  done
  return 1
}

cmd_apply() {
  load_conf; validate_conf; ensure_networks
  local tmp changed=false
  tmp="$(mktemp)"; generate_compose "$tmp"
  if [[ ! -f "$COMPOSE" ]] || ! cmp -s "$tmp" "$COMPOSE"; then
    [[ -f "$COMPOSE" ]] && cp "$COMPOSE" "$COMPOSE.prev"
    install -m 644 "$tmp" "$COMPOSE"; changed=true
  fi
  rm -f "$tmp"
  if ! docker compose -f "$COMPOSE" config --quiet; then
    [[ -f "$COMPOSE.prev" ]] && mv "$COMPOSE.prev" "$COMPOSE"
    die "Compose do proxy inválido — versão anterior restaurada"
  fi
  # As portas 80/443 precisam estar livres (ou já serem do próprio proxy)
  local p holder
  for p in 80 443; do
    holder="$(docker ps --filter "publish=$p" --format '{{.Names}}' | grep -vx "$CONTAINER" | head -1 || true)"
    [[ -z "$holder" ]] || die "Porta $p em uso pelo container '$holder'${holder:+ (Coolify? use: sudo $0 migrate-coolify)}"
  done
  $changed && log "Configuração do proxy atualizada"
  if ! docker compose -f "$COMPOSE" up -d --remove-orphans; then
    if [[ -f "$COMPOSE.prev" ]]; then
      warn "Falha ao subir — voltando à configuração anterior"
      mv "$COMPOSE.prev" "$COMPOSE"; docker compose -f "$COMPOSE" up -d --remove-orphans || true
    fi
    die "docker compose up falhou (imagem existe? portas livres?)"
  fi
  if wait_healthy; then
    ok "Proxy no ar ($TRAEFIK_IMAGE)"
    rm -f "$COMPOSE.prev"
  else
    docker logs --tail 20 "$CONTAINER" 2>&1 | sed 's/^/    /' >&2 || true
    if [[ -f "$COMPOSE.prev" ]]; then
      warn "Proxy não ficou saudável — voltando à configuração anterior"
      mv "$COMPOSE.prev" "$COMPOSE"; docker compose -f "$COMPOSE" up -d --remove-orphans || true
    fi
    die "Proxy não ficou saudável (veja: sudo $0 logs)"
  fi
  # certificado da LAN (CA do homelab) — gera o arquivo dinâmico se faltar
  [[ -x "$HOMELAB_DIR/scripts/homelab-ca.sh" ]] && "$HOMELAB_DIR/scripts/homelab-ca.sh" renew >/dev/null 2>&1 || true
}

# Containers com traefik.enable=true cuja rede (label traefik.docker.network ou a padrão do proxy)
# não é alcançável: o container não está nela, ou o proxy não está nela → "no available server".
check_routes() {
  local c name net nets proxy_nets bad=0 total=0
  proxy_nets=" $(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$CONTAINER" 2>/dev/null) "
  while read -r c; do
    [[ -n "$c" ]] || continue
    name="$(docker inspect -f '{{.Name}}' "$c")"; name="${name#/}"
    [[ "$name" == "$CONTAINER" ]] && continue
    total=$((total + 1))
    net="$(docker inspect -f '{{index .Config.Labels "traefik.docker.network"}}' "$c")"
    nets=" $(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c") "
    if [[ -z "$net" ]]; then
      # sem label: o Traefik usa a rede padrão do proxy; se o container não estiver nela, usa a
      # PRIMEIRA rede do container — que pode ser uma que o proxy não alcança (502/504)
      local n shared=0 count=0
      for n in $nets; do count=$((count + 1)); [[ "$proxy_nets" == *" $n "* ]] && shared=$((shared + 1)); done
      if [[ "$nets" != *" $PROXY_NETWORK "* ]] && { (( shared == 0 )) || (( count > 1 )); }; then
        bad=1; warn "$name: sem traefik.docker.network e fora da rede '$PROXY_NETWORK' (redes:${nets% })"
        echo "     → no compose do projeto, adicione a label  traefik.docker.network=<rede em comum com o proxy>  (ex.: ${PROXY_NETWORK}) e rode docker compose up -d" >&2
      fi
    elif [[ "$nets" != *" $net "* ]]; then
      bad=1; warn "$name: traefik.docker.network=$net, mas o container não está nessa rede (redes:${nets% })"
    elif [[ "$proxy_nets" != *" $net "* ]]; then
      bad=1; warn "$name: rede '$net' não está conectada ao proxy → acrescente em PROXY_EXTRA_NETWORKS e rode: sudo $0 apply"
    fi
  done < <(docker ps -q --filter label=traefik.enable=true)
  if (( bad == 0 )); then ok "$total container(s) com rotas: redes OK"; fi
  return "$bad"
}

cmd_status() {
  load_conf
  local s img
  s="$(docker inspect -f '{{.State.Status}}{{if .State.Health}} ({{.State.Health.Status}}){{end}}' "$CONTAINER" 2>/dev/null || echo 'não instalado')"
  img="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || echo -)"
  echo "Proxy ......... $s  [$img]"
  echo "Config ........ $CONF"
  echo "Rede .......... $PROXY_NETWORK${PROXY_EXTRA_NETWORKS:+ (+ $PROXY_EXTRA_NETWORKS)}"
  echo "Portas LAN .... 80 443${PROXY_ENTRYPOINTS:+ | $PROXY_ENTRYPOINTS}"
  echo "Let's Encrypt . desafio $ACME_CHALLENGE$([[ "$ACME_CHALLENGE" == tls ]] && echo ' (porta 443)' || echo ' (porta 80)')"
  if [[ -s "$PROXY_DIR/acme/acme.json" ]] && command -v jq >/dev/null; then
    local certs; certs="$(jq -r '[.[]?.Certificates[]?.domain.main] | join(", ")' "$PROXY_DIR/acme/acme.json" 2>/dev/null || echo '?')"
    echo "Certificados .. ${certs:-nenhum emitido ainda}"
  fi
  [[ -f "$PROXY_DIR/dynamic/homelab-lan.yaml" ]] && echo "LAN (CA) ...... $PROXY_DIR/dynamic/homelab-lan.yaml" || echo "LAN (CA) ...... não configurado (homelab-ca.sh)"
  echo "Rotas ......... containers com traefik.enable=true:"
  check_routes || true
  if [[ -d "$COOLIFY_DIR" ]]; then
    echo
    if docker ps --format '{{.Names}}' | grep -qx coolify-proxy; then
      echo "Coolify ativo em $COOLIFY_DIR — migre com: sudo $0 migrate-coolify"
    else
      echo "Coolify parado (migrado). Com tudo testado: sudo $0 remove-coolify  | voltar: sudo $0 rollback-coolify"
    fi
  fi
}

# Aplica uma mudança de proxy.conf; se o proxy não subir, devolve o proxy.conf anterior
apply_or_revert() {
  if ! ( cmd_apply ); then
    install -m 644 "$CONF.prev" "$CONF"
    die "Mudança desfeita em $CONF (o proxy segue com a configuração anterior)"
  fi
  rm -f "$CONF.prev"
}

cmd_entrypoint() {
  load_conf
  local action="${1:-}" name="${2:-}" port="${3:-}" ep new=""
  cp "$CONF" "$CONF.prev"
  case "$action" in
    add)
      valid_ep_name "$name" || die "Uso: $0 entrypoint add <nome> <porta>"
      [[ "$port" =~ ^[0-9]+$ ]] || die "Porta inválida"
      for ep in $PROXY_ENTRYPOINTS; do [[ "${ep%%=*}" == "$name" ]] || new+="${new:+ }$ep"; done
      new+="${new:+ }$name=$port"
      set_conf PROXY_ENTRYPOINTS "$new"; log "Entrypoint $name → :$port" ;;
    remove)
      [[ -n "$name" ]] || die "Uso: $0 entrypoint remove <nome>"
      for ep in $PROXY_ENTRYPOINTS; do [[ "${ep%%=*}" == "$name" ]] || new+="${new:+ }$ep"; done
      set_conf PROXY_ENTRYPOINTS "$new"; log "Entrypoint $name removido" ;;
    *) die "Uso: $0 entrypoint add <nome> <porta> | remove <nome>" ;;
  esac
  apply_or_revert
}

cmd_acme() {
  load_conf
  [[ "${1:-}" =~ ^(tls|http)$ ]] || die "Uso: $0 acme tls|http [email]"
  cp "$CONF" "$CONF.prev"
  set_conf ACME_CHALLENGE "$1"
  [[ -n "${2:-}" ]] && set_conf ACME_EMAIL "$2"
  apply_or_revert
}

cmd_image() {
  load_conf
  [[ "${1:-}" =~ ^traefik:v3\.[0-9]+(\.[0-9]+)?$ ]] || die "Uso: $0 image traefik:v3.X"
  docker image inspect "$1" >/dev/null 2>&1 || docker pull -q "$1" >/dev/null || die "Não foi possível baixar $1"
  cp "$CONF" "$CONF.prev"
  set_conf TRAEFIK_IMAGE "$1"
  apply_or_revert
}

cmd_logs() { docker logs --since "${1:-30m}" "$CONTAINER" 2>&1 | grep -E ' (ERR|WRN) |acme|ACME' | tail -30 || true; }

# ---------------------------------------------------------------- Coolify
coolify_containers() { docker ps -a --format '{{.Names}}' | grep -E '^coolify(-db|-redis|-realtime|-sentinel|-proxy)?$' || true; }

cmd_migrate_coolify() {
  [[ -d "$COOLIFY_PROXY" ]] || die "Coolify não encontrado em $COOLIFY_DIR — nada a migrar"
  load_conf
  local stamp bk f ep name port eps="" cf="$COOLIFY_PROXY/docker-compose.yml"
  stamp="$(date +%Y%m%d-%H%M%S)"
  bk="$HOMELAB_DIR/backups/coolify-final-$stamp"

  log "1/6 Backup do Coolify → $bk"
  install -d -m 750 "$bk"
  if docker ps --format '{{.Names}}' | grep -qx coolify-db; then
    docker exec coolify-db pg_dump -U coolify -d coolify -Fc > "$bk/coolify-db.dump" && ok "banco do Coolify"
  else
    warn "coolify-db parado — banco não exportado"
  fi
  tar czf "$bk/coolify-data.tar.gz" -C / --exclude='data/coolify/backups' --exclude='data/coolify/applications/*/.git' \
    "${COOLIFY_DIR#/}" && ok "arquivos de $COOLIFY_DIR"

  log "2/6 Importando configuração do proxy do Coolify"
  if [[ -f "$cf" ]]; then
    while read -r name port; do
      [[ "$name" =~ ^(http|https|traefik)$ ]] && continue
      valid_ep_name "$name" || continue
      eps+="${eps:+ }$name=$port"
    done < <(grep -oE -- '--entrypoints\.[A-Za-z0-9-]+\.address=:[0-9]+' "$cf" | sed -E 's/--entrypoints\.([^.]+)\.address=:([0-9]+)/\1 \2/' | sort -u)
    # junta com os que já existirem em proxy.conf (o do Coolify vence em caso de mesmo nome)
    local merged="$eps" e
    for e in $PROXY_ENTRYPOINTS; do [[ " $eps " == *" ${e%%=*}="* ]] || merged+="${merged:+ }$e"; done
    if [[ -n "$merged" ]]; then set_conf PROXY_ENTRYPOINTS "$merged"; ok "entrypoints: $merged"; fi
    if grep -q 'acme.httpchallenge' "$cf" && ! grep -q 'acme.tlschallenge=true' "$cf"; then
      set_conf ACME_CHALLENGE http
    else
      set_conf ACME_CHALLENGE tls
    fi
    load_conf; ok "Let's Encrypt: desafio $ACME_CHALLENGE"
  fi
  # projetos existentes usam a rede "coolify" (traefik.docker.network=coolify): o proxy entra nela também
  docker network inspect coolify >/dev/null 2>&1 && set_conf PROXY_EXTRA_NETWORKS "coolify" && ok "rede legada: coolify"
  # certificados Let's Encrypt já emitidos (evita reemissão e limite do Let's Encrypt)
  if [[ -s "$COOLIFY_PROXY/acme.json" && ! -s "$PROXY_DIR/acme/acme.json" ]]; then
    install -m 600 "$COOLIFY_PROXY/acme.json" "$PROXY_DIR/acme/acme.json"; ok "acme.json (certificados Let's Encrypt)"
  elif [[ -s "$PROXY_DIR/acme/acme.json" ]]; then
    ok "acme.json do proxy do homelab mantido (já existia)"
  fi
  # certificado da LAN: se a CA do homelab não tiver o lan.crt, aproveita o que estava no Coolify
  if [[ ! -s "$HOMELAB_DIR/ca/lan.crt" && -s "$COOLIFY_PROXY/certs/homelab-lan.crt" ]]; then
    install -d -m 700 "$HOMELAB_DIR/ca"
    install -m 644 "$COOLIFY_PROXY/certs/homelab-lan.crt" "$HOMELAB_DIR/ca/lan.crt"
    install -m 600 "$COOLIFY_PROXY/certs/homelab-lan.key" "$HOMELAB_DIR/ca/lan.key"
    ok "certificado da LAN"
  fi
  # arquivos dinâmicos próprios (rotas em arquivo); os do Coolify e o da CA ficam de fora
  for f in "$COOLIFY_PROXY"/dynamic/*.y*ml; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in coolify*|default_redirect*|homelab-lan.yaml) continue ;; esac
    sed 's#/traefik/certs/#/certs/#g' "$f" > "$PROXY_DIR/dynamic/$(basename "$f")"; ok "rota em arquivo: $(basename "$f")"
  done
  load_conf

  log "3/6 Certificado da LAN no novo proxy"
  PROXY_DIR="$PROXY_DIR" "$HOMELAB_DIR/scripts/homelab-ca.sh" renew || warn "homelab-ca.sh renew falhou — rode depois: sudo homelab-ca.sh issue"

  log "4/6 Parando o Coolify (sem remover — dá para voltar com rollback-coolify)"
  local c
  for c in $(coolify_containers) $(docker ps -aq --filter label=coolify.managed=true); do
    docker update --restart=no "$c" >/dev/null 2>&1 || true
    docker stop "$c" >/dev/null 2>&1 || true
  done
  ok "Coolify parado"

  log "5/6 Subindo o proxy do homelab"
  if ! ( cmd_apply ); then
    warn "Falhou — religando o Coolify"
    cmd_rollback_coolify
    die "Migração desfeita. Veja: docker logs $CONTAINER"
  fi

  log "6/6 Conferência"
  check_routes || warn "Corrija os itens acima (no compose de cada projeto) — senão essas rotas respondem 'no available server'"
  local ip; ip="$(hostname -I | awk '{print $1}')"
  for ep in 443 ${PROXY_ENTRYPOINTS}; do
    port="${ep##*=}"
    echo "    https://$ip:$port → $(curl --noproxy '*' -sk -o /dev/null -w '%{http_code}' -m 5 "https://$ip:$port/" || echo 000)"
  done
  echo
  ok "Migração concluída. Teste os sistemas (LAN e domínios). Se algo falhar: sudo $0 rollback-coolify"
  echo "  Com tudo certo, remova o Coolify de vez: sudo $0 remove-coolify"
}

cmd_rollback_coolify() {
  [[ -d "$COOLIFY_DIR" ]] || die "Coolify já foi removido — rollback indisponível (backup em $HOMELAB_DIR/backups/coolify-final-*)"
  docker compose -f "$COMPOSE" down >/dev/null 2>&1 || docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  local c
  for c in $(coolify_containers); do
    docker update --restart=always "$c" >/dev/null 2>&1 || true
    docker start "$c" >/dev/null 2>&1 || true
  done
  ok "Coolify religado (proxy do Coolify de volta nas portas 80/443)"
}

cmd_remove_coolify() {
  [[ -d "$COOLIFY_DIR" ]] || { echo "Coolify já removido"; return 0; }
  ls -d "$HOMELAB_DIR"/backups/coolify-final-* >/dev/null 2>&1 \
    || die "Sem backup do Coolify — rode antes: sudo $0 migrate-coolify"
  docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null | grep -qx healthy \
    || die "O proxy do homelab não está saudável — corrija antes de remover o Coolify"
  echo "Isto remove DEFINITIVAMENTE o Coolify (containers, volumes, $COOLIFY_DIR)."
  echo "Backup: $(find "$HOMELAB_DIR/backups" -maxdepth 1 -name 'coolify-final-*' | sort | tail -1)"
  read -r -p "Digite REMOVER para confirmar: " ans
  [[ "$ans" == "REMOVER" ]] || die "Cancelado"
  local c
  for c in $(docker ps -aq --filter label=coolify.managed=true) $(coolify_containers); do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  docker volume ls -q | grep -E '^coolify[-_]' | xargs -r docker volume rm >/dev/null 2>&1 || true
  rm -rf "$COOLIFY_DIR"
  # chave SSH que o Coolify usava para administrar o host como root
  [[ -f /root/.ssh/authorized_keys ]] && sed -i '/coolify/d' /root/.ssh/authorized_keys
  ok "Coolify removido"
  echo "  A rede 'coolify' continua (projetos ainda conectados a ela). Para migrar um projeto para a"
  echo "  rede 'proxy': troque coolify → proxy no compose dele (networks e traefik.docker.network)."
  echo "  Rode também: sudo ./homelab-setup.sh  (fecha o SSH de root e as regras de firewall do Coolify)"
}

case "${1:-status}" in
  status)           cmd_status ;;
  check)            load_conf; check_routes ;;
  apply|up)         cmd_apply ;;
  entrypoint)       shift; cmd_entrypoint "$@" ;;
  acme)             shift; cmd_acme "$@" ;;
  image)            shift; cmd_image "$@" ;;
  logs)             shift; cmd_logs "$@" ;;
  migrate-coolify)  cmd_migrate_coolify ;;
  rollback-coolify) cmd_rollback_coolify ;;
  remove-coolify)   cmd_remove_coolify ;;
  -h|--help)        sed -n '2,/^set -Eeuo/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
  *) die "Comando desconhecido: $1 (veja: $0 --help)" ;;
esac
