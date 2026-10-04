#!/usr/bin/env bash
# shellcheck source=/dev/null
[[ -r "${HOMELAB_CONF:-/etc/homelab.conf}" ]] && . "${HOMELAB_CONF:-/etc/homelab.conf}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
BACKUP_GROUP="${BACKUP_GROUP:-root}"
# Backup do homelab: MySQL, Redis, RabbitMQ (definições), Coolify e configurações (inclui a CA).
# Uso: sudo backup.sh [all|mysql|redis|rabbitmq|coolify|config ...]
#      sudo backup.sh --sync-external      # só copia para o SSD externo
# Agendado diariamente pelo homelab-backup.timer (systemd).
# Backup completo: grava em $HOMELAB_DIR/backups e copia para o SSD externo
# (configurado por backup-disk-setup.sh).
set -Eeuo pipefail

INFRA="$HOMELAB_DIR/infra"
ENV_FILE="$INFRA/.env"
ROOT="$HOMELAB_DIR/backups"

[[ $EUID -eq 0 ]] || { echo "Execute com sudo: sudo $0 $*" >&2; exit 1; }
[[ -r "$ENV_FILE" ]] || { echo "Arquivo $ENV_FILE não encontrado" >&2; exit 1; }

envget() { grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2- || true; }
log()    { echo "[$(date '+%F %T')] $*"; }

KEEP_DAYS="${KEEP_DAYS:-$(envget BACKUP_KEEP_DAYS)}"
KEEP_DAYS="${KEEP_DAYS:-7}"
EXT_MNT="$(envget BACKUP_EXTERNAL_MOUNT)"
EXT_DIR="$(envget BACKUP_EXTERNAL_DIR)"
EXT_KEEP="$(envget BACKUP_EXTERNAL_KEEP_DAYS)"
EXT_KEEP="${EXT_KEEP:-30}"

SYNC_ONLY=0
if [[ "${1:-}" == "--sync-external" ]]; then SYNC_ONLY=1; shift; fi

COMPONENTS=("$@")
if [[ ${#COMPONENTS[@]} -eq 0 || "${COMPONENTS[0]}" == "all" ]]; then
  COMPONENTS=(mysql redis rabbitmq coolify config)
  FULL_RUN=1
else
  FULL_RUN=0
fi

# Um backup por vez
exec 9>/run/homelab-backup.lock
flock -n 9 || { log "Outro backup já está em execução"; exit 1; }

# ------------------------------------------------ Cópia para o SSD externo
# Copia todo backup local que ainda não está no SSD (recupera dias em que ele
# estava desconectado), confere os checksums na cópia e aplica a retenção do SSD.
sync_external() {
  if [[ -z "$EXT_MNT" || -z "$EXT_DIR" ]]; then
    log "SSD externo não configurado (rode backup-disk-setup.sh) — cópia externa ignorada"
    return 0
  fi
  # nofail no fstab: sem o disco, o diretório existe vazio no disco interno — nunca grave nele
  mountpoint -q "$EXT_MNT" || mount "$EXT_MNT" 2>/dev/null || true
  if ! mountpoint -q "$EXT_MNT"; then
    log "✘ SSD externo não está montado em $EXT_MNT — conecte o disco"
    return 1
  fi
  mkdir -p "$EXT_DIR"
  rm -rf "$EXT_DIR"/*.partial

  local d name copied=0 latest
  for d in "$ROOT"/20??-??-??_*; do
    [[ -f "$d/SHA256SUMS" ]] || continue
    name="$(basename "$d")"
    [[ -d "$EXT_DIR/$name" ]] && continue
    rsync -a "$d/" "$EXT_DIR/$name.partial/" || { log "✘ falha ao copiar $name"; return 1; }
    if ! (cd "$EXT_DIR/$name.partial" && sha256sum -c --quiet SHA256SUMS); then
      log "✘ checksum divergente na cópia de $name"
      return 1
    fi
    mv "$EXT_DIR/$name.partial" "$EXT_DIR/$name"
    copied=$(( copied + 1 ))
  done

  latest="$(readlink "$ROOT/latest" 2>/dev/null || true)"
  if [[ -n "$latest" && -d "$EXT_DIR/$latest" ]]; then ln -sfn "$latest" "$EXT_DIR/latest"; fi
  find "$EXT_DIR" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??_*' \
    -mtime +"$EXT_KEEP" -print -exec rm -rf {} + | sed 's/^/  removido do SSD: /'
  sync
  log "SSD externo: ${copied} backup(s) copiado(s) | livre: $(df -h --output=avail "$EXT_MNT" | tail -1 | tr -d ' ') | retenção: ${EXT_KEEP} dias"
}

if (( SYNC_ONLY )); then
  sync_external && exit 0
  exit 2
fi

FAILED=()

mkdir -p "$ROOT"
AVAIL_KB="$(df --output=avail -k "$ROOT" | tail -1 | tr -d ' ')"
if (( AVAIL_KB < 1048576 )); then
  log "Menos de 1 GB livre em $ROOT — backup abortado"
  exit 1
fi

STAMP="$(date +%F_%H%M%S)"
DEST="$ROOT/$STAMP"
umask 027
mkdir -p "$DEST"
FAILED=()

container_up() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }
volume_of()    { docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Name}}{{end}}{{end}}" "$1" 2>/dev/null; }

# ------------------------------------------------------------------- MySQL
backup_mysql() {
  container_up mysql || { log "  container mysql não está rodando"; return 1; }
  local out="$DEST/mysql-all.sql.gz"
  docker exec -e MYSQL_PWD="$(envget MYSQL_ROOT_PASSWORD)" mysql \
    mysqldump -uroot --all-databases --single-transaction --quick \
      --routines --triggers --events --hex-blob \
    | gzip > "$out" || return 1
  gzip -t "$out" || return 1
  # mysqldump grava esta linha só quando termina com sucesso
  zcat "$out" | tail -n 1 | grep -q 'Dump completed' || { log "  dump incompleto"; return 1; }
}

# ------------------------------------------------------------------- Redis
backup_redis() {
  container_up redis || { log "  container redis não está rodando"; return 1; }
  local pass t0 info last i saved=0
  pass="$(envget REDIS_PASSWORD)"
  rcli() { docker exec -e REDISCLI_AUTH="$pass" redis redis-cli "$@" | tr -d '\r'; }

  # Relógio do próprio Redis: LASTSAVE tem resolução de segundos, então
  # considera concluído o save que terminar no mesmo segundo ou depois de t0.
  t0="$(rcli TIME | head -n 1)" || return 1
  rcli BGSAVE SCHEDULE >/dev/null || return 1
  for (( i = 0; i < 300; i++ )); do
    sleep 1
    info="$(rcli INFO persistence)" || return 1
    last="$(grep '^rdb_last_save_time:' <<<"$info" | cut -d: -f2)"
    if grep -q '^rdb_bgsave_in_progress:0' <<<"$info" && (( last >= t0 )); then saved=1; break; fi
  done
  (( saved )) || { log "  BGSAVE não concluiu em 300s"; return 1; }
  rcli INFO persistence | grep -q '^rdb_last_bgsave_status:ok' || { log "  BGSAVE falhou"; return 1; }

  local dir file
  dir="$(rcli CONFIG GET dir | sed -n 2p)"
  file="$(rcli CONFIG GET dbfilename | sed -n 2p)"
  docker exec redis cat "${dir:-/data}/${file:-dump.rdb}" | gzip > "$DEST/redis-dump.rdb.gz" || return 1
  gzip -t "$DEST/redis-dump.rdb.gz" || return 1
  rcli DBSIZE | sed 's/^/  chaves no db0: /'
}

# ---------------------------------------------------------------- RabbitMQ
backup_rabbitmq() {
  container_up rabbitmq || { log "  container rabbitmq não está rodando"; return 1; }
  local out="$DEST/rabbitmq-definitions.json"
  docker exec rabbitmq rabbitmqctl -q export_definitions /tmp/definitions.json >/dev/null || return 1
  docker exec rabbitmq cat /tmp/definitions.json > "$out" || return 1
  docker exec rabbitmq rm -f /tmp/definitions.json || true
  jq -e '.vhosts and .users' "$out" >/dev/null || { log "  JSON de definições inválido"; return 1; }
}

# ----------------------------------------------------------------- Coolify
# Banco do Coolify (pg_dump) + /data/coolify: chave APP_KEY (source/.env — sem ela os
# segredos salvos no banco não podem ser lidos), chaves SSH, proxy (acme.json, dynamic,
# certs) e configurações das aplicações. Os volumes de dados das apps não entram aqui.
backup_coolify() {
  if [[ ! -d /data/coolify ]]; then log "  Coolify não instalado — pulando"; return 0; fi
  container_up coolify-db || { log "  container coolify-db não está rodando"; return 1; }
  docker exec coolify-db pg_dump -U coolify -d coolify -Fc > "$DEST/coolify-db.dump" || return 1
  [[ -s "$DEST/coolify-db.dump" ]] || { log "  dump do Coolify vazio"; return 1; }
  tar czf "$DEST/coolify-data.tar.gz" -C / --exclude=data/coolify/backups \
    --exclude='data/coolify/applications/*/.git' data/coolify || return 1
  gzip -t "$DEST/coolify-data.tar.gz" || return 1
}

# ----------------------------------------------------------- Configurações
backup_config() {
  local candidates=(
    "$INFRA/docker-compose.yml" "$INFRA/.env" "$INFRA/mysql"
    "$HOMELAB_DIR/ca"
    /etc/homelab.conf
    /etc/ssh/sshd_config.d/00-homelab.conf
    /etc/fail2ban/jail.d/homelab.local
    /etc/ufw
    /etc/docker/daemon.json
    /etc/avahi/avahi-daemon.conf
    /etc/tlp.d/01-homelab.conf
    /etc/systemd/logind.conf.d/99-homelab-lid.conf
    /etc/sysctl.d/99-homelab.conf
    /etc/systemd/system/homelab-backup.service
    /etc/systemd/system/homelab-backup.timer
    /etc/systemd/system/homelab-ca-renew.service
    /etc/systemd/system/homelab-ca-renew.timer
    /etc/netplan
  )
  local rel=() p
  for p in "${candidates[@]}"; do
    [[ -e "$p" ]] && rel+=("${p#/}")
  done
  # Projetos em compose próprio ($HOMELAB_DIR/apps/<projeto>): compose, overrides, .env e
  # rotas públicas (public-routes.conf). Código-fonte e volumes de dados não entram.
  if [[ -d "$HOMELAB_DIR/apps" ]]; then
    while IFS= read -r -d '' p; do rel+=("${p#/}"); done < <(
      find "$HOMELAB_DIR/apps" -mindepth 2 -maxdepth 2 -type f \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
        -o -name 'compose*.yml' -o -name 'compose*.yaml' -o -name '.env' -o -name '.env.*' -o -name 'public-routes.conf' \) -print0)
  fi
  tar czf "$DEST/config.tar.gz" -C / "${rel[@]}" || return 1
  gzip -t "$DEST/config.tar.gz" || return 1
}

# --------------------------------------------------------------- Execução
log "Backup iniciado → $DEST (${COMPONENTS[*]})"
for c in "${COMPONENTS[@]}"; do
  if ! declare -F "backup_$c" >/dev/null; then
    log "✘ componente desconhecido: $c"; FAILED+=("$c"); continue
  fi
  log "→ $c"
  if "backup_$c"; then log "✔ $c"; else log "✘ $c FALHOU"; FAILED+=("$c"); fi
done

if compgen -G "$DEST/*" >/dev/null; then
  (cd "$DEST" && sha256sum -- * > SHA256SUMS)
fi
chown -R "root:$BACKUP_GROUP" "$DEST"
chmod 750 "$DEST"
find "$DEST" -type f -exec chmod 640 {} +
log "Tamanho: $(du -sh "$DEST" | cut -f1)"

if (( ${#FAILED[@]} )); then
  log "Backup concluído COM FALHAS: ${FAILED[*]} — retenção não aplicada"
  exit 1
fi

if (( FULL_RUN )); then
  ln -sfn "$STAMP" "$ROOT/latest"
  # retenção só após um backup completo bem-sucedido
  find "$ROOT" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??_*' \
    -mtime +"$KEEP_DAYS" -print -exec rm -rf {} + | sed 's/^/  removido: /'

  if ! sync_external; then
    log "Backup local concluído, mas a cópia para o SSD externo FALHOU"
    exit 2
  fi
fi
log "Backup concluído com sucesso"
