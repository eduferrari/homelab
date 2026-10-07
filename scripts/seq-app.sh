#!/usr/bin/env bash
# Liga um serviço de um projeto Docker Compose ao Seq do homelab (logs estruturados, monitor.sh):
#   1. coloca o serviço na rede do proxy (onde o Seq está) — e migra a rede "coolify" legada;
#   2. define Seq__ServerUrl e Seq__ApiKey no environment do serviço (a chave fica no .env
#      do projeto, fora do Git: Seq__ApiKey: ${SEQ_APIKEY_<SERVIÇO>});
#   3. recria o serviço (sem -f: o override das rotas públicas continua valendo);
#   4. envia um evento de teste pela rede do próprio container e confere a chave.
#
#   seq-app.sh [-C DIR] add <serviço> [--key CHAVE | --sem-chave] [--yes]
#   seq-app.sh [-C DIR] check [serviço]        # rede, variáveis e envio de teste
#
# Exemplo:
#   cd /opt/homelab/apps/<projeto>
#   seq-app.sh add api                          # pede a chave criada no Seq (Settings → API Keys)
#
# A aplicação precisa do sink do Seq no código (Serilog.Sinks.Seq lendo Seq:ServerUrl e
# Seq:ApiKey) — veja o README, seção 7.6.
set -Eeuo pipefail
# shellcheck source=/dev/null
[[ -r "${HOMELAB_CONF:-/etc/homelab.conf}" ]] && . "${HOMELAB_CONF:-/etc/homelab.conf}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
PROXY_DIR="${PROXY_DIR:-$HOMELAB_DIR/proxy}"
SEQ_URL="${SEQ_URL:-http://seq:5341}"
SEQ_CONTAINER="${SEQ_CONTAINER:-seq}"
CURL_IMAGE="${CURL_IMAGE:-curlimages/curl:latest}"
DIR="$PWD"; KEY=""; NO_KEY=false; YES=false

die()  { echo "✘ $*" >&2; exit 1; }
log()  { echo "==> $*"; }
ok()   { echo "  ✔ $*"; }
warn() { echo "  ! $*" >&2; }
usage() { sed -n '2,/^set -Eeuo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C) DIR="${2:?-C exige um diretório}"; shift 2 ;;
    --key) KEY="${2:?--key exige a chave}"; shift 2 ;;
    --sem-chave) NO_KEY=true; shift ;;
    --yes|-y) YES=true; shift ;;
    -h|--help) usage ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"
CMD="${1:-}"; shift || true
[[ -n "$CMD" ]] || usage 1

DIR="$(cd "$DIR" && pwd)" || die "Diretório inválido"
COMPOSE_FILE=""
for f in docker-compose.yml compose.yml docker-compose.yaml compose.yaml; do
  [[ -f "$DIR/$f" ]] && { COMPOSE_FILE="$DIR/$f"; break; }
done
[[ -n "$COMPOSE_FILE" ]] || die "Nenhum docker-compose.yml em $DIR (use -C <pasta do projeto>)"
ENV_FILE="$DIR/.env"
command -v docker >/dev/null || die "docker não encontrado"
docker info >/dev/null 2>&1 || die "Sem acesso ao Docker (usuário no grupo docker? ou use sudo)"
command -v python3 >/dev/null || die "python3 não encontrado"
compose() { docker compose --project-directory "$DIR" "$@"; }   # sem -f: inclui o override

PROXY_NETWORK="proxy"
# shellcheck source=/dev/null
[[ -r "$PROXY_DIR/proxy.conf" ]] && PROXY_NETWORK="$(. "$PROXY_DIR/proxy.conf"; echo "${PROXY_NETWORK:-proxy}")"

key_var() { echo "SEQ_APIKEY_$(tr '[:lower:]-.' '[:upper:]__' <<<"$1")"; }
container_of() { compose ps -q "$1" 2>/dev/null | head -1; }

set_env() {   # set_env VAR valor  (no .env do projeto, criando com 640 se não existir)
  [[ -f "$ENV_FILE" ]] || { install -m 640 /dev/null "$ENV_FILE"; }
  local tmp; tmp="$(mktemp)"
  awk -v k="$1" -v v="$2" 'BEGIN{d=0} index($0, k"=")==1{print k"="v; d=1; next} {print} END{if(!d) print k"="v}' "$ENV_FILE" > "$tmp"
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"   # cat mantém dono e permissões do .env
}

# Edita o compose preservando comentários e formatação (só as linhas do serviço mudam).
#   edit_compose ARQ SERVIÇO REDE MIGRAR(0|1) VAR_DA_CHAVE(ou vazio) URL
edit_compose() {
  python3 - "$@" <<'PY'
import re, sys
path, svc, net, migrate, keyvar, url = sys.argv[1:7]
text = open(path, encoding="utf-8").read()
if migrate == "1":
    text = re.sub(r"\bcoolify\b", net, text)
lines = text.split("\n")

def indent(l): return len(l) - len(l.lstrip(" "))
def blank(l): return not l.strip() or l.lstrip().startswith("#")

def block(start, base):
    """fim (exclusivo) do bloco que começa em start com indentação > base"""
    i = start
    while i < len(lines) and (blank(lines[i]) or indent(lines[i]) > base):
        i += 1
    while i > start and blank(lines[i - 1]):
        i -= 1
    return i

def child_indent(start, end, default):
    for j in range(start, end):
        if not blank(lines[j]):
            return indent(lines[j])
    return default

# serviço
try:
    s0 = next(i for i, l in enumerate(lines) if re.match(r"^services:\s*$", l))
except StopIteration:
    sys.exit("compose sem 'services:'")
s_end = block(s0 + 1, 0)
si = child_indent(s0 + 1, s_end, 2)
try:
    a = next(i for i in range(s0 + 1, s_end) if indent(lines[i]) == si and re.match(rf"^\s*{re.escape(svc)}:\s*(#.*)?$", lines[i]))
except StopIteration:
    sys.exit(f"serviço '{svc}' não encontrado em {path}")
b = block(a + 1, si)
ci = child_indent(a + 1, b, si + 2)
pad = " " * ci

def find_key(key):
    for i in range(a + 1, b):
        if indent(lines[i]) == ci and re.match(rf"^\s*{key}:", lines[i]):
            return i
    return None

changes = []
# ---- redes do serviço
n = find_key("networks")
if n is None:
    lines.insert(b, f"{pad}networks: [default, {net}]"); b += 1
    changes.append(f"{svc}: networks: [default, {net}]")
else:
    m = re.match(r"^(\s*networks:\s*)\[(.*)\]\s*(#.*)?$", lines[n])
    if m:
        items = [x.strip() for x in m.group(2).split(",") if x.strip()]
        if net not in items:
            items.append(net)
            lines[n] = f"{m.group(1)}[{', '.join(items)}]" + (f"  {m.group(3)}" if m.group(3) else "")
            changes.append(f"{svc}: rede {net} adicionada")
    else:
        e = block(n + 1, ci)
        sub = [lines[j] for j in range(n + 1, e) if not blank(lines[j])]
        names = [re.sub(r"^\s*-\s*", "", l).split(":")[0].strip() for l in sub]
        if net not in names:
            ii = indent(sub[0]) if sub else ci + 2
            new = f"{' ' * ii}- {net}" if sub and sub[0].lstrip().startswith("-") else f"{' ' * ii}{net}: {{}}"
            lines.insert(e, new); b += 1
            changes.append(f"{svc}: rede {net} adicionada")

# ---- environment do serviço
want = {"Seq__ServerUrl": url}
if keyvar:
    want["Seq__ApiKey"] = "${" + keyvar + "}"
n = find_key("environment")
if n is None:
    lines[b:b] = [f"{pad}environment:"] + [f"{pad}  {k}: {v}" for k, v in want.items()]
    b += 1 + len(want)
    changes.append(f"{svc}: environment com " + ", ".join(want))
elif re.match(r"^\s*environment:\s*(#.*)?$", lines[n]):
    e = block(n + 1, ci)
    sub_idx = [j for j in range(n + 1, e) if not blank(lines[j])]
    ii = indent(lines[sub_idx[0]]) if sub_idx else ci + 2
    listy = bool(sub_idx) and lines[sub_idx[0]].lstrip().startswith("-")
    for k, v in want.items():
        fmt = f"{' ' * ii}- {k}={v}" if listy else f"{' ' * ii}{k}: {v}"
        hit = next((j for j in sub_idx if re.match(rf"^\s*(-\s*)?{re.escape(k)}\s*[:=]", lines[j])), None)
        if hit is not None:
            if lines[hit] != fmt:
                lines[hit] = fmt; changes.append(f"{svc}: {k} atualizado")
        else:
            lines.insert(e, fmt); e += 1; b += 1; changes.append(f"{svc}: {k} adicionado")
else:
    sys.exit(f"'environment' do serviço {svc} em formato não suportado (use bloco: CHAVE: valor)")

# ---- rede declarada no fim do arquivo
t = next((i for i, l in enumerate(lines) if re.match(r"^networks:\s*(#.*)?$", l)), None)
if t is None:
    while lines and not lines[-1].strip():
        lines.pop()
    lines += ["", "networks:", f"  {net}:", "    external: true", ""]
    changes.append(f"networks: {net} (external)")
else:
    e = block(t + 1, 0)
    ti = child_indent(t + 1, e, 2)
    if not any(indent(lines[j]) == ti and re.match(rf"^\s*{re.escape(net)}:", lines[j]) for j in range(t + 1, e)):
        lines[e:e] = [f"{' ' * ti}{net}:", f"{' ' * (ti * 2)}external: true"]
        changes.append(f"networks: {net} (external)")

open(path, "w", encoding="utf-8").write("\n".join(lines))
print("\n".join(changes))
PY
}

# Envia um evento de teste pela rede do container do serviço (mesmo DNS que a aplicação usa).
send_test() {   # send_test CONTAINER CHAVE SERVIÇO  → imprime o código HTTP
  local c="$1" key="$2" svc="$3" body hdr=()
  [[ -n "$key" ]] && hdr=(-H "X-Seq-ApiKey: $key")
  body="{\"@t\":\"$(date -u +%FT%TZ)\",\"@mt\":\"Teste do homelab: {Servico} ligado ao Seq\",\"Servico\":\"$svc\",\"Origem\":\"seq-app.sh\"}"
  docker run --rm --network "container:$c" "$CURL_IMAGE" -s -o /dev/null -w '%{http_code}' -m 10 \
    -X POST "$SEQ_URL/ingest/clef" -H 'Content-Type: application/vnd.serilog.clef' \
    "${hdr[@]}" --data "$body" 2>/dev/null || echo 000
}

check_service() {
  local svc="$1" c nets envs url key code res=0
  c="$(container_of "$svc")"
  [[ -n "$c" ]] || { warn "$svc: não está rodando"; return 1; }
  nets="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c")"
  envs="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c")"
  url="$(grep -oP '^Seq__ServerUrl=\K.*' <<<"$envs" || true)"
  key="$(grep -oP '^Seq__ApiKey=\K.*' <<<"$envs" || true)"
  echo "$svc"
  if [[ " $nets " == *" $PROXY_NETWORK "* ]]; then ok "rede $PROXY_NETWORK"; else warn "fora da rede $PROXY_NETWORK (redes: ${nets% }) — rode: $0 add $svc"; res=1; fi
  if [[ -n "$url" ]]; then ok "Seq__ServerUrl=$url"; else warn "sem Seq__ServerUrl"; res=1; fi
  if [[ -n "$key" ]]; then ok "Seq__ApiKey definida"; else echo "  · sem Seq__ApiKey (o Seq aceita, mas sem identificar a origem)"; fi
  if (( res == 0 )); then
    code="$(SEQ_URL="$url" send_test "$c" "$key" "$svc")"
    case "$code" in
      2??) ok "evento de teste aceito (HTTP $code) — procure \"Teste do homelab\" no Seq" ;;
      401|403) warn "Seq recusou a chave (HTTP $code) — confira a chave em Settings → API Keys"; res=1 ;;
      000) warn "Seq inalcançável a partir do container ($url)"; res=1 ;;
      *) warn "Seq respondeu HTTP $code"; res=1 ;;
    esac
  fi
  return "$res"
}

cmd_add() {
  local svc="${1:-}" migrate=0 keyvar="" bak changes
  [[ -n "$svc" ]] || die "Uso: $0 add <serviço> [--key CHAVE | --sem-chave]"
  compose config --quiet || die "docker compose config falhou em $DIR — corrija o compose antes"
  local services; services="$(compose config --services)"   # (grep -q num pipe + pipefail = falso negativo)
  grep -qx "$svc" <<<"$services" || die "Serviço '$svc' não existe (serviços: $(xargs <<<"$services"))"
  grep -qx "$SEQ_CONTAINER" <<<"$(docker ps --format '{{.Names}}')" || warn "Seq não está rodando (sudo $HOMELAB_DIR/scripts/monitor.sh) — configurando assim mesmo"

  # rede legada do Coolify: migra o arquivo todo (todos os serviços e labels) para a rede do proxy
  if grep -qw coolify "$COMPOSE_FILE"; then
    if grep -qwE "^\s*${PROXY_NETWORK}:" "$COMPOSE_FILE"; then
      warn "O compose usa as redes coolify e $PROXY_NETWORK — troque coolify por $PROXY_NETWORK à mão; só adiciono $PROXY_NETWORK ao serviço"
    else
      echo "O compose ainda usa a rede legada 'coolify'. Ela será trocada por '$PROXY_NETWORK' em TODOS os serviços"
      echo "(networks e traefik.docker.network). O proxy está nas duas redes: as rotas seguem funcionando."
      if ! $YES; then read -rp "Continuar? [s/N] " r; [[ "$r" =~ ^[sSyY]$ ]] || die "Cancelado"; fi
      migrate=1
    fi
  fi

  # chave
  if ! $NO_KEY; then
    if [[ -z "$KEY" ]]; then
      if [[ -t 0 ]]; then
        echo "Crie a chave no Seq: https://$(hostname).local:9446 → Settings → API Keys → Add API Key (título: $(basename "$DIR")-$svc)"
        read -rsp "Cole a chave (Enter vazio = sem chave): " KEY; echo
      fi
    fi
    [[ -n "$KEY" ]] && { [[ "$KEY" =~ ^[A-Za-z0-9]+$ ]] || die "Chave inválida (só letras e números)"; keyvar="$(key_var "$svc")"; }
  fi

  bak="$COMPOSE_FILE.bak-$(date +%F_%H%M%S)"
  cp -p "$COMPOSE_FILE" "$bak"
  changes="$(edit_compose "$COMPOSE_FILE" "$svc" "$PROXY_NETWORK" "$migrate" "$keyvar" "$SEQ_URL")" \
    || { cp -p "$bak" "$COMPOSE_FILE"; die "Não foi possível editar o compose (original restaurado)"; }
  [[ -n "$keyvar" ]] && set_env "$keyvar" "$KEY"
  if ! compose config --quiet; then
    cp -p "$bak" "$COMPOSE_FILE"; die "Compose inválido após a edição — original restaurado ($bak)"
  fi
  if [[ -z "$changes" && $migrate == 0 ]]; then
    rm -f "$bak"; ok "Compose já configurado"
  else
    log "Compose atualizado (backup: $(basename "$bak"))"
    sed 's/^/  · /' <<<"$changes"
    (( migrate )) && echo "  · coolify → $PROXY_NETWORK em todo o arquivo"
  fi
  [[ -n "$keyvar" ]] && ok "Chave em $ENV_FILE ($keyvar)"

  log "Recriando ${svc}$( (( migrate )) && echo " e os demais serviços (troca de rede)")"
  if (( migrate )); then compose up -d; else compose up -d "$svc"; fi
  echo
  check_service "$svc" || true
  [[ -f "$DIR/public-routes.conf" && -x "$HOMELAB_DIR/scripts/public-route.sh" ]] && { echo; "$HOMELAB_DIR/scripts/public-route.sh" -C "$DIR" check || true; }
  echo
  echo "Falta só o código: Serilog.Sinks.Seq lendo Seq:ServerUrl e Seq:ApiKey (README, seção 7.6)."
}

cmd_check() {
  local svc res=0
  if [[ -n "${1:-}" ]]; then check_service "$1"; return; fi
  for svc in $(compose config --services); do check_service "$svc" || res=1; echo; done
  return "$res"
}

case "$CMD" in
  add)   cmd_add "$@" ;;
  check) cmd_check "$@" ;;
  *) usage 1 ;;
esac
