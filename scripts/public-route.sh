#!/usr/bin/env bash
# Publica serviços de um projeto Docker Compose na internet por domínio, pelo proxy do Coolify
# (Traefik + Let's Encrypt), SEM mexer no docker-compose.yml do projeto.
#
# As rotas públicas ficam no docker-compose.override.yml do projeto, gerado a partir de
# public-routes.conf (uma linha por domínio: "<serviço> <domínio>"). As rotas da LAN continuam
# como estão; o script apenas reaproveita o serviço Traefik e os middlewares delas.
#
#   public-route.sh [-C DIR] add <serviço> <domínio>      # publica (e aplica)
#   public-route.sh [-C DIR] remove <serviço> [domínio]   # despublica (e aplica)
#   public-route.sh [-C DIR] list                         # rotas públicas configuradas
#   public-route.sh [-C DIR] apply                        # regenera o override e recria os serviços
#   public-route.sh [-C DIR] check                        # testa as rotas e procura conflitos
#
# Exemplo (MesaFácil):
#   cd /opt/homelab/apps/mesafacil
#   public-route.sh add api mfapi.darkocode.com.br
#   public-route.sh add pdv mf.pdv.darkocode.com.br
#   public-route.sh add crm mfcrm.darkocode.com.br
#
# Requisitos de cada serviço: container rodando, rede do Coolify e uma label
# traefik.http.services.<nome>.loadbalancer.server.port (o script usa esse <nome>).
# DNS, encaminhamento 80/443 e firewall: veja public-access.sh (README, seção 9.4).
set -Eeuo pipefail

MARKER="# gerado por public-route.sh"
CONF_NAME="public-routes.conf"
OVERRIDE_NAME="docker-compose.override.yml"
RESOLVER="${PUBLIC_ROUTE_RESOLVER:-letsencrypt}"
WAIT_SECS=0
LAN_ONLY_RE='^homelab-lan-only(@file)?$'   # middlewares da LAN que NÃO vão para a rota pública
DIR="$PWD"
FORCE=false

die()  { echo "✘ $*" >&2; exit 1; }
log()  { echo "==> $*"; }
warn() { echo "  ! $*" >&2; }
usage() { sed -n '2,/^set -Eeuo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -C) DIR="${2:?-C exige um diretório}"; shift 2 ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done
CMD="${1:-}"; shift || true
[[ -n "$CMD" ]] || usage 1

DIR="$(cd "$DIR" && pwd)" || die "Diretório inválido"
CONF="$DIR/$CONF_NAME"
OVERRIDE="$DIR/$OVERRIDE_NAME"
compose() { docker compose --project-directory "$DIR" "$@"; }

[[ -f "$DIR/docker-compose.yml" || -f "$DIR/compose.yml" || -f "$DIR/docker-compose.yaml" || -f "$DIR/compose.yaml" ]] \
  || die "Nenhum docker-compose.yml em $DIR (use -C <pasta do projeto>)"
command -v docker >/dev/null || die "docker não encontrado"
docker info >/dev/null 2>&1 || die "Sem acesso ao Docker (usuário no grupo docker? ou use sudo)"

valid_domain() { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }

# Labels do container de um serviço do compose ("chave=valor" por linha).
container_of() { compose ps -q "$1" 2>/dev/null | head -1; }
labels_of() {
  local c; c="$(container_of "$1")"
  [[ -n "$c" ]] || die "Serviço '$1' não está rodando em $DIR (docker compose up -d $1)"
  docker inspect "$c" --format '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}'
}

# Lê do container: serviço Traefik, routers da LAN e middlewares a reaproveitar.
#   saída: TSV "svc<TAB>routers(espaço)<TAB>middlewares(vírgula)<TAB>network"
inspect_service() {
  local name="$1" labels svc routers r mws="" network
  labels="$(labels_of "$name")"
  grep -q '^traefik.enable=true$' <<<"$labels" || die "Serviço '$name' sem traefik.enable=true"
  svc="$(grep -oP '^traefik\.http\.services\.\K[^.]+(?=\.loadbalancer\.server\.port=)' <<<"$labels" | head -1 || true)"
  [[ -n "$svc" ]] || die "Serviço '$name' sem label traefik.http.services.<nome>.loadbalancer.server.port"
  # routers definidos pelo projeto (exclui os gerados aqui)
  routers="$(grep -oP '^traefik\.http\.routers\.\K[^.]+(?=\.rule=)' <<<"$labels" | grep -v -- '-pub\(-http\)\?$' | sort -u | xargs || true)"
  for r in $routers; do
    local m; m="$(grep -oP "^traefik\.http\.routers\.${r//./\\.}\.middlewares=\K.*" <<<"$labels" || true)"
    [[ -n "$m" ]] || continue
    local x; IFS=',' read -ra arr <<<"$m"
    for x in "${arr[@]}"; do
      x="$(xargs <<<"$x")"
      [[ "$x" =~ $LAN_ONLY_RE ]] && continue
      [[ ",$mws," == *",$x,"* ]] || mws="${mws:+$mws,}$x"
    done
    break   # middlewares do primeiro router da LAN bastam
  done
  network="$(grep -oP '^traefik\.docker\.network=\K.*' <<<"$labels" || true)"
  [[ -n "$network" ]] || warn "Serviço '$name' sem traefik.docker.network — se estiver em mais de uma rede, defina =coolify"
  printf '%s\t%s\t%s\t%s\n' "$svc" "$routers" "$mws" "$network"
}

conf_entries() { [[ -f "$CONF" ]] && grep -vE '^\s*(#|$)' "$CONF" | awk 'NF>=2{print $1, $2}' || true; }
conf_services() { conf_entries | awk '{print $1}' | sort -u; }

ensure_override_owned() {
  [[ -f "$OVERRIDE" ]] || return 0
  head -1 "$OVERRIDE" | grep -qF "$MARKER" && return 0
  if $FORCE; then
    local bak; bak="$OVERRIDE.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$OVERRIDE" "$bak"; log "Override anterior salvo em $bak"
  else
    die "$OVERRIDE existe e não foi gerado por este script.
  Revise o conteúdo; se só tiver rotas públicas, rode de novo com --force (faz backup)."
  fi
}

generate_override() {
  local tmp name info svc routers mws domains rule r
  tmp="$(mktemp)"
  {
    echo "$MARKER — não edite; use: public-route.sh add|remove|apply ($CONF_NAME)"
    echo "# Rotas públicas (internet) pelo Traefik do Coolify + Let's Encrypt."
  } > "$tmp"
  if [[ -z "$(conf_services)" ]]; then
    echo "services: {}" >> "$tmp"
  else
    echo "services:" >> "$tmp"
    for name in $(conf_services); do
      info="$(inspect_service "$name")"
      IFS=$'\t' read -r svc routers mws _ <<<"$info"
      domains="$(conf_entries | awk -v s="$name" '$1==s{print $2}' | sort -u)"
      rule=""
      for d in $domains; do rule="${rule:+$rule || }Host(\`$d\`)"; done
      {
        echo "  $name:"
        echo "    labels:"
        # com mais de um router no container o Traefik exige o serviço explícito em cada um
        for r in $routers; do echo "      - traefik.http.routers.$r.service=$svc"; done
        echo "      - traefik.http.routers.$svc-pub.entrypoints=https"
        echo "      - traefik.http.routers.$svc-pub.rule=$rule"
        echo "      - traefik.http.routers.$svc-pub.tls=true"
        echo "      - traefik.http.routers.$svc-pub.tls.certresolver=$RESOLVER"
        [[ -n "$mws" ]] && echo "      - traefik.http.routers.$svc-pub.middlewares=$mws"
        echo "      - traefik.http.routers.$svc-pub.service=$svc"
        echo "      - traefik.http.routers.$svc-pub-http.entrypoints=http"
        echo "      - traefik.http.routers.$svc-pub-http.rule=$rule"
        echo "      - traefik.http.routers.$svc-pub-http.middlewares=homelab-redirect-https@file"
        echo "      - traefik.http.routers.$svc-pub-http.service=$svc"
      } >> "$tmp"
    done
  fi
  echo "$tmp"
}

# Containers de OUTROS projetos (ex.: recursos do Coolify) que declaram o mesmo domínio.
# Regras mais longas têm prioridade no Traefik — ex.: Host(`x`) && PathPrefix(`/`) vence Host(`x`).
find_conflicts() {
  local domain="$1" project c line found=1
  project="$(compose config --format json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || true)"
  for c in $(docker ps -aq); do
    line="$(docker inspect "$c" --format '{{.Name}}|{{.State.Status}}|{{index .Config.Labels "com.docker.compose.project"}}|{{range $k,$v := .Config.Labels}}{{$k}}={{$v}};{{end}}')"
    [[ "$line" == *"Host(\`$domain\`)"* ]] || continue
    IFS='|' read -r cname cstate cproj _ <<<"$line"
    [[ -n "$project" && "$cproj" == "$project" ]] && continue
    found=0
    warn "Conflito: ${cname#/} ($cstate) também declara $domain"
    if [[ "$cname" == "/coolify-proxy" ]]; then
      echo "     → labels esquecidas no proxy: sudo sed -i '/$domain/d;/-pub/d' /data/coolify/proxy/docker-compose.yml (revise antes)"
    else
      echo "     → recurso do Coolify? Abra-o no Coolify, Stop e apague Domains (ou: docker update --restart=no ${cname#/} && docker stop ${cname#/})"
    fi
  done
  if [[ -d /data/coolify/proxy/dynamic ]] && grep -rlsF "$domain" /data/coolify/proxy/dynamic/ 2>/dev/null | grep -q .; then
    found=0; warn "Conflito: $domain aparece em $(grep -rlsF "$domain" /data/coolify/proxy/dynamic/ | xargs)"
  fi
  return "$found"
}

cmd_apply() {
  local tmp changed=() name
  ensure_override_owned
  tmp="$(generate_override)"
  if [[ -f "$OVERRIDE" ]] && cmp -s "$tmp" "$OVERRIDE"; then
    rm -f "$tmp"; log "Override já atualizado"
  else
    [[ -f "$OVERRIDE" ]] && cp "$OVERRIDE" "$OVERRIDE.prev"
    install -m 644 "$tmp" "$OVERRIDE"; rm -f "$tmp"
    if ! compose config --quiet; then
      if [[ -f "$OVERRIDE.prev" ]]; then mv "$OVERRIDE.prev" "$OVERRIDE"; else rm -f "$OVERRIDE"; fi
      die "docker compose config falhou — override revertido"
    fi
    log "Override gerado: $OVERRIDE"
  fi
  rm -f "$OVERRIDE.prev"
  # recria os serviços cujas labels mudaram (inclusive os que saíram do conf)
  for name in $(compose config --services); do
    local c want have
    c="$(container_of "$name")"; [[ -n "$c" ]] || continue
    want="$(compose config --format json 2>/dev/null | python3 -c "
import json,sys; d=json.load(sys.stdin)['services'].get('$name',{}).get('labels',{})
d=d if isinstance(d,dict) else dict(x.split('=',1) for x in d)
print('\n'.join(sorted(f'{k}={v}' for k,v in d.items() if '-pub' in k)))")"
    have="$(docker inspect "$c" --format '{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' | grep -- '-pub' | sort || true)"
    [[ "$want" == "$have" ]] || changed+=("$name")
  done
  if (( ${#changed[@]} )); then
    log "Recriando: ${changed[*]}"
    compose up -d --no-deps "${changed[@]}"
    WAIT_SECS=20   # o Traefik leva alguns segundos para ler as labels novas
  else
    log "Nenhum serviço precisa ser recriado"
  fi
  cmd_check
}

cmd_add() {
  local name="${1:-}" domain="${2:-}"
  [[ -n "$name" && -n "$domain" ]] || die "Uso: $0 add <serviço> <domínio>"
  domain="${domain,,}"
  valid_domain "$domain" || die "Domínio inválido: $domain"
  compose config --services | grep -qx "$name" || die "Serviço '$name' não existe no compose de $DIR"
  ensure_override_owned
  inspect_service "$name" >/dev/null
  local other; other="$(conf_entries | awk -v d="$domain" -v s="$name" '$2==d && $1!=s{print $1}')"
  [[ -z "$other" ]] || die "$domain já está publicado no serviço '$other'"
  if conf_entries | grep -qx "$name $domain"; then
    log "$domain já configurado em '$name'"
  else
    [[ -f "$CONF" ]] || printf '# Rotas públicas — <serviço do compose> <domínio>. Gerencie com public-route.sh.\n' > "$CONF"
    echo "$name $domain" >> "$CONF"
    log "Adicionado: $name → https://$domain"
  fi
  cmd_apply
}

cmd_remove() {
  local name="${1:-}" domain="${2:-}"
  [[ -n "$name" ]] || die "Uso: $0 remove <serviço> [domínio]"
  [[ -f "$CONF" ]] || die "Nada configurado em $CONF"
  ensure_override_owned
  local tmp; tmp="$(mktemp)"
  awk -v s="$name" -v d="${domain,,}" '/^[ \t]*(#|$)/ {print; next} !($1==s && (d=="" || $2==d)) {print}' "$CONF" > "$tmp"
  if cmp -s "$tmp" "$CONF"; then rm -f "$tmp"; die "Nenhuma rota de '$name'${domain:+ para $domain}"; fi
  install -m 644 "$tmp" "$CONF"; rm -f "$tmp"
  log "Removido: $name${domain:+ $domain}"
  cmd_apply
}

cmd_list() {
  if [[ -z "$(conf_entries)" ]]; then echo "Nenhuma rota pública em $DIR"; return; fi
  conf_entries | awk '{printf "  %-12s https://%s\n", $1, $2}'
}

cmd_check() {
  local name domain code ok=0
  [[ -n "$(conf_entries)" ]] || { echo "Nenhuma rota pública configurada"; return 0; }
  echo "Rotas públicas (teste local no Traefik, sem passar pelo roteador):"
  while read -r name domain; do
    local waited=0
    while :; do
      code="$(curl --noproxy "*" -sk -o /dev/null -w '%{http_code}' -m 10 --resolve "$domain:443:127.0.0.1" "https://$domain/" 2>/dev/null || true)"
      if [[ ! "${code:-000}" =~ ^(000|404|502|503)$ ]] || (( waited >= WAIT_SECS )); then break; fi
      sleep 2; waited=$((waited + 2))
    done
    case "${code:-000}" in
      000) echo "  ✘ $domain ($name) → sem resposta (proxy do Coolify no ar?)"; ok=1 ;;
      502|503|504) echo "  ✘ $domain ($name) → HTTP $code (container fora do ar ou outra rota disputando o domínio)"; ok=1 ;;
      *) echo "  ✔ $domain ($name) → HTTP $code" ;;
    esac
    find_conflicts "$domain" && ok=1
  done < <(conf_entries)
  echo
  echo "DNS, portas e certificado: sudo /opt/homelab/scripts/public-access.sh check <domínio>"
  return "$ok"
}

case "$CMD" in
  add)    cmd_add "$@" ;;
  remove) cmd_remove "$@" ;;
  list)   cmd_list ;;
  apply)  cmd_apply ;;
  check)  cmd_check ;;
  *) usage 1 ;;
esac
