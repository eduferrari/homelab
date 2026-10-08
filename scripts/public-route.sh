#!/usr/bin/env bash
# Publica serviços de um projeto Docker Compose na internet por domínio, pelo proxy do homelab
# (Traefik + Let's Encrypt), SEM mexer no compose do projeto.
#
# As rotas públicas ficam na configuração do próprio proxy ($PROXY_DIR/dynamic/public-<projeto>.yaml),
# geradas a partir de public-routes.conf (uma linha por domínio: "<serviço> <domínio>") e
# apontando para o serviço Traefik que o container já declara nas labels. Por isso elas
# sobrevivem a qualquer deploy: compose com ou sem -f, container recriado ou trocado.
# As rotas da LAN continuam como estão; o script reaproveita o serviço e os middlewares delas.
#
#   public-route.sh [-C DIR] add <serviço> <domínio>      # publica (e aplica)
#   public-route.sh [-C DIR] remove <serviço> [domínio]   # despublica (e aplica)
#   public-route.sh [-C DIR] list                         # rotas públicas configuradas
#   public-route.sh [-C DIR] apply                        # regenera as rotas no proxy
#   public-route.sh [-C DIR] check                        # testa as rotas e procura conflitos
#
# Exemplo:
#   cd /opt/homelab/apps/<projeto>
#   public-route.sh add api api.seudominio.com.br
#   public-route.sh add web app.seudominio.com.br
#
# Requisitos de cada serviço: na rede do proxy (proxy), com traefik.enable=true e uma label
# traefik.http.services.<nome>.loadbalancer.server.port (o script usa esse <nome>).
# DNS, encaminhamento 80/443 e firewall: veja public-access.sh (README, seção 9.4).
# Versões anteriores geravam docker-compose.override.yml; o apply migra (backup + remoção).
set -Eeuo pipefail
# shellcheck source=/dev/null
[[ -r "${HOMELAB_CONF:-/etc/homelab.conf}" ]] && . "${HOMELAB_CONF:-/etc/homelab.conf}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
PROXY_DIR="${PROXY_DIR:-$HOMELAB_DIR/proxy}"
DYN_DIR="$PROXY_DIR/dynamic"

MARKER="# gerado por public-route.sh"
CONF_NAME="public-routes.conf"
OVERRIDE_NAME="docker-compose.override.yml"
RESOLVER="${PUBLIC_ROUTE_RESOLVER:-letsencrypt}"
WAIT_SECS=0
LAN_ONLY_RE='^homelab-lan-only(@file)?$'   # middlewares da LAN que NÃO vão para a rota pública
DIR="$PWD"

die()  { echo "✘ $*" >&2; exit 1; }
log()  { echo "==> $*"; }
ok()   { echo "  ✔ $*"; }
warn() { echo "  ! $*" >&2; }
usage() { sed -n '2,/^set -Eeuo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -C) DIR="${2:?-C exige um diretório}"; shift 2 ;;
    --force) shift ;;   # compatibilidade com versões anteriores (não é mais necessário)
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
command -v python3 >/dev/null || die "python3 não encontrado"
docker info >/dev/null 2>&1 || die "Sem acesso ao Docker (usuário no grupo docker? ou use sudo)"

valid_domain() { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }
conf_entries() { [[ -f "$CONF" ]] && grep -vE '^\s*(#|$)' "$CONF" | awk 'NF>=2{print $1, $2}' || true; }
conf_services() { conf_entries | awk '{print $1}' | sort -u; }
container_of() { compose ps -q "$1" 2>/dev/null | head -1; }

# Config do projeto já mesclada (compose + override, se houver); valida o compose.
CONFIG_JSON=""
config_json() {
  [[ -n "$CONFIG_JSON" ]] && return 0
  CONFIG_JSON="$(compose config --format json)" || die "docker compose config falhou em $DIR — corrija o compose antes (erro acima)"
}
project_name() {
  config_json
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' <<<"$CONFIG_JSON"
}
services_list() { config_json; python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["services"]))' <<<"$CONFIG_JSON"; }

# Labels do serviço no compose ("chave=valor" por linha).
labels_of() {
  config_json
  python3 -c '
import json, sys
s = json.load(sys.stdin)["services"].get(sys.argv[1])
if s is None: sys.exit(3)
d = s.get("labels") or {}
d = d if isinstance(d, dict) else dict(x.split("=", 1) for x in d)
print("\n".join(f"{k}={v}" for k, v in sorted(d.items())))
' "$1" <<<"$CONFIG_JSON" || die "Serviço '$1' não existe no compose de $DIR"
}

# Do compose: serviço Traefik e middlewares da rota da LAN a reaproveitar.
#   saída: "svc|middlewares(vírgula, com @provedor)"
inspect_service() {
  local name="$1" labels svc routers r mws="" network
  labels="$(labels_of "$name" | grep -v -- '-pub\(-http\)\?\.' || true)"
  grep -q '^traefik.enable=true$' <<<"$labels" || die "Serviço '$name' sem traefik.enable=true"
  svc="$(grep -oP '^traefik\.http\.services\.\K[^.]+(?=\.loadbalancer\.server\.port=)' <<<"$labels" | head -1 || true)"
  [[ -n "$svc" ]] || die "Serviço '$name' sem label traefik.http.services.<nome>.loadbalancer.server.port"
  routers="$(grep -oP '^traefik\.http\.routers\.\K[^.]+(?=\.rule=)' <<<"$labels" | sort -u | xargs || true)"
  for r in $routers; do
    local m; m="$(grep -oP "^traefik\.http\.routers\.${r//./\\.}\.middlewares=\K.*" <<<"$labels" || true)"
    [[ -n "$m" ]] || continue
    local x; IFS=',' read -ra arr <<<"$m"
    for x in "${arr[@]}"; do
      x="$(xargs <<<"$x")"
      [[ "$x" =~ $LAN_ONLY_RE ]] && continue
      [[ "$x" == *@* ]] || x="$x@docker"   # middleware das labels: provedor docker
      [[ ",$mws," == *",$x,"* ]] || mws="${mws:+$mws,}$x"
    done
    break   # middlewares do primeiro router da LAN bastam
  done
  network="$(grep -oP '^traefik\.docker\.network=\K.*' <<<"$labels" || true)"
  [[ -n "$network" ]] || warn "Serviço '$name' sem traefik.docker.network — se estiver em mais de uma rede, defina =proxy"
  printf '%s|%s\n' "$svc" "$mws"
}

DYN_FILE=""
dyn_file() {
  [[ -n "$DYN_FILE" ]] && return 0
  local p; p="$(project_name)"; [[ -n "$p" ]] || p="$(basename "$DIR")"
  DYN_FILE="$DYN_DIR/public-${p}.yaml"
}

# Gera o arquivo de rotas do projeto (YAML do provedor de arquivo do Traefik).
generate_routes() {
  local out="$1" name info svc mws domains rule d id
  local project; project="$(project_name)"
  {
    echo "$MARKER — projeto $project ($CONF). Não edite: use public-route.sh add|remove|apply."
    echo "# Rotas públicas (internet) + Let's Encrypt, apontando para o serviço Traefik do container."
    echo "http:"
    echo "  routers:"
    for name in $(conf_services); do
      info="$(inspect_service "$name")"
      IFS='|' read -r svc mws <<<"$info"
      domains="$(conf_entries | awk -v s="$name" '$1==s{print $2}' | sort -u)"
      rule=""
      for d in $domains; do rule="${rule:+$rule || }Host(\`$d\`)"; done
      id="${project}-${name}-pub"
      echo "    ${id}:"
      echo "      entryPoints: [https]"
      echo "      rule: '${rule}'"
      echo "      service: ${svc}@docker"
      [[ -n "$mws" ]] && echo "      middlewares: [${mws//,/, }]"
      echo "      tls:"
      echo "        certResolver: ${RESOLVER}"
      echo "    ${id}-http:"
      echo "      entryPoints: [http]"
      echo "      rule: '${rule}'"
      echo "      service: ${svc}@docker"
      echo "      middlewares: [homelab-redirect-https@file]"
    done
  } > "$out"
}

# Versões anteriores: rotas no docker-compose.override.yml (label -pub). Remove (com backup)
# e recria os serviços para tirar as labels antigas do container.
migrate_override() {
  [[ -f "$OVERRIDE" ]] || return 0
  if ! head -1 "$OVERRIDE" | grep -qF "$MARKER"; then
    grep -q -- '-pub' "$OVERRIDE" && warn "$OVERRIDE (feito à mão) declara rotas -pub: remova-as para não duplicar as rotas públicas"
    return 0
  fi
  local bak svcs
  bak="$OVERRIDE.bak-$(date +%F_%H%M%S)"
  svcs="$(python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["services"]))' <<<"$CONFIG_JSON" || true)"
  mv "$OVERRIDE" "$bak"
  CONFIG_JSON=""; config_json
  log "Migrando: rotas públicas saem do $OVERRIDE_NAME (backup: $(basename "$bak")) e vão para o proxy"
  local s c recreate=()
  for s in $svcs; do
    c="$(container_of "$s")"; [[ -n "$c" ]] || continue
    docker inspect "$c" --format '{{range $k,$v := .Config.Labels}}{{$k}}{{"\n"}}{{end}}' | grep -q -- '-pub' && recreate+=("$s")
  done
  if (( ${#recreate[@]} )); then
    log "Recriando sem as labels antigas: ${recreate[*]}"
    compose up -d --no-deps "${recreate[@]}"
  fi
}

cmd_apply() {
  config_json
  dyn_file
  [[ -d "$DYN_DIR" ]] || die "Proxy do homelab não encontrado ($DYN_DIR) — sudo $HOMELAB_DIR/scripts/proxy.sh apply"
  [[ -w "$DYN_DIR" ]] || die "Sem permissão em $DYN_DIR — rode com sudo, ou atualize o proxy (sudo $HOMELAB_DIR/scripts/proxy.sh apply libera o grupo docker)"
  local tmp; tmp="$(mktemp)"
  if [[ -z "$(conf_services)" ]]; then
    rm -f "$tmp"
    if [[ -f "$DYN_FILE" ]]; then rm -f "$DYN_FILE"; log "Rotas públicas removidas do proxy ($(basename "$DYN_FILE"))"; fi
  else
    generate_routes "$tmp"
    if [[ -f "$DYN_FILE" ]] && cmp -s "$tmp" "$DYN_FILE"; then
      rm -f "$tmp"; log "Rotas no proxy já atualizadas ($DYN_FILE)"
    else
      install -m 644 "$tmp" "$DYN_FILE"; rm -f "$tmp"
      log "Rotas no proxy: $DYN_FILE"
      WAIT_SECS=15   # o Traefik relê o diretório em alguns segundos
    fi
  fi
  migrate_override
  cmd_check
}

cmd_add() {
  local name="${1:-}" domain="${2:-}"
  [[ -n "$name" && -n "$domain" ]] || die "Uso: $0 add <serviço> <domínio>"
  domain="${domain,,}"
  valid_domain "$domain" || die "Domínio inválido: $domain"
  local services; services="$(services_list)"
  grep -qx "$name" <<<"$services" || die "Serviço '$name' não existe no compose de $DIR (serviços: $(xargs <<<"$services"))"
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
  local tmp; tmp="$(mktemp)"
  awk -v s="$name" -v d="${domain,,}" '/^[ \t]*(#|$)/ {print; next} !($1==s && (d=="" || $2==d)) {print}' "$CONF" > "$tmp"
  if cmp -s "$tmp" "$CONF"; then rm -f "$tmp"; die "Nenhuma rota de '$name'${domain:+ para $domain}"; fi
  cat "$tmp" > "$CONF"; rm -f "$tmp"
  log "Removido: $name${domain:+ $domain}"
  cmd_apply
}

cmd_list() {
  if [[ -z "$(conf_entries)" ]]; then echo "Nenhuma rota pública em $DIR"; return; fi
  conf_entries | awk '{printf "  %-12s https://%s\n", $1, $2}'
  dyn_file; echo "  (no proxy: $DYN_FILE)"
}

# Outras rotas com o mesmo domínio: containers de OUTROS projetos e arquivos do proxy que não
# são deste projeto. Regras mais longas têm prioridade no Traefik — ex.: Host(`x`) && PathPrefix(`/`) vence Host(`x`).
find_conflicts() {
  local domain="$1" project c line found=1 f
  project="$(project_name)"; dyn_file
  for c in $(docker ps -aq); do
    line="$(docker inspect "$c" --format '{{.Name}}|{{.State.Status}}|{{index .Config.Labels "com.docker.compose.project"}}|{{range $k,$v := .Config.Labels}}{{$k}}={{$v}};{{end}}')"
    [[ "$line" == *"Host(\`$domain\`)"* ]] || continue
    IFS='|' read -r cname cstate cproj _ <<<"$line"
    if [[ -n "$project" && "$cproj" == "$project" ]]; then
      [[ "$line" == *"-pub.rule="* ]] && warn "${cname#/} ainda tem as labels antigas (-pub) — rode: $0 apply"
      continue
    fi
    found=0
    warn "Conflito: ${cname#/} ($cstate) também declara $domain"
    if [[ "$cstate" =~ ^(exited|created|dead)$ ]]; then
      warn "  (parado: não atrapalha agora, mas volta a disputar o domínio se for religado)"
      echo "     → remova o container (docker rm ${cname#/}) ou a rota dele no projeto de origem" >&2
    else
      echo "     → tire o domínio do outro projeto (${cproj:-sem projeto}) ou pare-o: docker update --restart=no ${cname#/} && docker stop ${cname#/}"
    fi
  done
  if [[ -d "$DYN_DIR" ]]; then
    while IFS= read -r f; do
      [[ "$f" == "$DYN_FILE" ]] && continue
      found=0; warn "Conflito: $domain aparece em $f"
    done < <(grep -rlsF "\`$domain\`" "$DYN_DIR" 2>/dev/null || true)
  fi
  return "$found"
}

cmd_check() {
  local name domain code ok=0 out body svc
  [[ -n "$(conf_entries)" ]] || { echo "Nenhuma rota pública configurada"; return 0; }
  config_json; dyn_file
  [[ -f "$DYN_FILE" ]] || warn "Rotas ainda não estão no proxy ($DYN_FILE) — rode: $0 apply"
  echo "Rotas públicas (teste local no Traefik, sem passar pelo roteador):"
  while read -r name domain; do
    local waited=0
    while :; do
      out="$(curl --noproxy "*" -sk --max-filesize 65536 -w '\n%{http_code}' -m 10 --resolve "$domain:443:127.0.0.1" "https://$domain/" 2>/dev/null || true)"
      code="${out##*$'\n'}"; body="${out%$'\n'*}"; body="${body%$'\n'}"
      if [[ ! "${code:-000}" =~ ^(000|404|502|503)$ ]] || (( waited >= WAIT_SECS )); then break; fi
      sleep 2; waited=$((waited + 2))
    done
    if [[ "$body" == "404 page not found" ]]; then
      svc="$(inspect_service "$name" 2>/dev/null | cut -d'|' -f1 || true)"
      if [[ -z "$(container_of "$name")" ]]; then
        echo "  ✘ $domain ($name) → 404 do Traefik: o container de '$name' não está rodando (docker compose up -d $name)"
      else
        echo "  ✘ $domain ($name) → 404 do Traefik: rota sem destino. Rode: $0 apply (serviço Traefik esperado: ${svc:-?}@docker)"
      fi
      ok=1
    else
      case "${code:-000}" in
        000) echo "  ✘ $domain ($name) → sem resposta (proxy no ar? sudo proxy.sh status)"; ok=1 ;;
        502|503|504) echo "  ✘ $domain ($name) → HTTP $code (container fora do ar, unhealthy ou outra rota disputando o domínio)"; ok=1 ;;
        *) echo "  ✔ $domain ($name) → HTTP $code" ;;
      esac
    fi
    find_conflicts "$domain" && ok=1
  done < <(conf_entries)
  echo
  echo "DNS, portas e certificado: sudo $HOMELAB_DIR/scripts/public-access.sh check <domínio>"
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
