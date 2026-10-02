#!/usr/bin/env bash
# shellcheck source=/dev/null
[[ -r "${HOMELAB_CONF:-/etc/homelab.conf}" ]] && . "${HOMELAB_CONF:-/etc/homelab.conf}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
# Restaura um componente a partir de um backup do homelab.
# Uso: sudo restore.sh <pasta-do-backup|latest> <mysql|redis|rabbitmq|coolify|config> [--yes]
set -Eeuo pipefail

INFRA="$HOMELAB_DIR/infra"
ENV_FILE="$INFRA/.env"
ROOT="$HOMELAB_DIR/backups"

[[ $EUID -eq 0 ]] || { echo "Execute com sudo: sudo $0 $*" >&2; exit 1; }

usage() {
  echo "Uso: sudo $0 <pasta-do-backup|latest> <mysql|redis|rabbitmq|coolify|config> [--yes]"
  echo "Backups disponíveis:"
  local d
  for d in "$ROOT"/20* "$ROOT"/latest; do [[ -e "$d" ]] && echo "  $(basename "$d")"; done
  exit 1
}
[[ $# -ge 2 ]] || usage

SRC="$1"; COMP="$2"; YES="${3:-}"
[[ "$SRC" == /* ]] || SRC="$ROOT/$SRC"
SRC="$(readlink -f "$SRC")"
[[ -d "$SRC" ]] || { echo "Backup não encontrado: $SRC" >&2; usage; }

envget() { grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2- || true; }
log()    { echo "[$(date +%T)] $*"; }
dc()     { docker compose -f "$INFRA/docker-compose.yml" "$@"; }
volume_of() { docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Name}}{{end}}{{end}}" "$1" 2>/dev/null; }

need() { [[ -f "$SRC/$1" ]] || { echo "Arquivo $1 não existe em $SRC" >&2; exit 1; }; }

confirm() {
  [[ "$YES" == "--yes" ]] && return 0
  echo "⚠️  $1"
  read -rp "Digite SIM para continuar: " answer
  [[ "$answer" == "SIM" ]] || { echo "Cancelado."; exit 1; }
}

# Confere a integridade dos arquivos antes de qualquer alteração
if [[ -f "$SRC/SHA256SUMS" ]]; then
  (cd "$SRC" && sha256sum -c --quiet SHA256SUMS) || { echo "Checksum inválido — backup corrompido" >&2; exit 1; }
fi

case "$COMP" in
  mysql)
    need mysql-all.sql.gz
    confirm "Isto SOBRESCREVE todos os bancos do MySQL (inclusive usuários) com o backup $(basename "$SRC")."
    log "Restaurando MySQL..."
    gunzip -c "$SRC/mysql-all.sql.gz" \
      | docker exec -i -e MYSQL_PWD="$(envget MYSQL_ROOT_PASSWORD)" mysql mysql -uroot
    docker exec -e MYSQL_PWD="$(envget MYSQL_ROOT_PASSWORD)" mysql mysql -uroot -e 'FLUSH PRIVILEGES;'
    log "MySQL restaurado."
    ;;

  redis)
    need redis-dump.rdb.gz
    confirm "Isto APAGA os dados atuais do Redis e carrega o snapshot de $(basename "$SRC")."
    PASS="$(envget REDIS_PASSWORD)"
    VOL="$(volume_of redis /data)"
    [[ -n "$VOL" ]] || { echo "Volume do Redis não encontrado" >&2; exit 1; }
    IMAGE="$(docker inspect -f '{{.Config.Image}}' redis)"

    log "Parando Redis..."
    dc stop redisinsight redis >/dev/null

    log "Substituindo dados no volume $VOL..."
    docker run --rm -i -v "$VOL":/data --entrypoint sh "$IMAGE" -c \
      'rm -rf /data/appendonlydir /data/*.aof /data/dump.rdb && gzip -dc > /data/dump.rdb && chown -R redis:redis /data' \
      < "$SRC/redis-dump.rdb.gz"

    # AOF está ativo: se o Redis subir direto, ignoraria o dump.rdb.
    # Sobe temporário sem AOF, carrega o RDB e regrava o AOF a partir da memória.
    log "Carregando snapshot e regenerando AOF..."
    docker rm -f redis-restore >/dev/null 2>&1 || true
    docker run -d --name redis-restore -v "$VOL":/data "$IMAGE" \
      redis-server --appendonly no --requirepass "$PASS" >/dev/null
    rcli() { docker exec -e REDISCLI_AUTH="$PASS" redis-restore redis-cli "$@" | tr -d '\r'; }
    for (( i = 0; i < 120; i++ )); do
      [[ "$(rcli PING 2>/dev/null)" == "PONG" ]] && break; sleep 1
    done
    [[ "$(rcli PING)" == "PONG" ]] || { echo "Redis temporário não respondeu" >&2; docker logs redis-restore | tail; exit 1; }
    rcli CONFIG SET appendonly yes >/dev/null
    for (( i = 0; i < 300; i++ )); do
      sleep 1
      INFO="$(rcli INFO persistence)"
      grep -q '^aof_rewrite_in_progress:0' <<<"$INFO" && grep -q '^aof_rewrite_scheduled:0' <<<"$INFO" \
        && grep -q '^aof_enabled:1' <<<"$INFO" && break
    done
    grep -q '^aof_last_bgrewrite_status:ok' <<<"$INFO" || { echo "Falha ao regenerar o AOF" >&2; exit 1; }
    log "Chaves restauradas: $(rcli DBSIZE)"
    rcli SHUTDOWN SAVE >/dev/null 2>&1 || true
    docker wait redis-restore >/dev/null 2>&1 || true
    docker rm -f redis-restore >/dev/null

    log "Subindo Redis da stack..."
    dc start redis redisinsight >/dev/null
    log "Redis restaurado."
    ;;

  rabbitmq)
    need rabbitmq-definitions.json
    confirm "Isto importa as definições (vhosts, usuários, filas, exchanges, bindings, policies) de $(basename "$SRC"). Mensagens NÃO fazem parte do backup."
    docker cp "$SRC/rabbitmq-definitions.json" rabbitmq:/tmp/definitions.json
    docker exec rabbitmq rabbitmqctl import_definitions /tmp/definitions.json
    docker exec rabbitmq rm -f /tmp/definitions.json
    log "Definições do RabbitMQ importadas."
    ;;

  coolify)
    need coolify-db.dump
    need coolify-data.tar.gz
    OUT="/tmp/homelab-coolify-$(basename "$SRC")"
    rm -rf "$OUT"; mkdir -p "$OUT"; chmod 700 "$OUT"
    tar xzf "$SRC/coolify-data.tar.gz" -C "$OUT"
    cp "$SRC/coolify-db.dump" "$OUT/"
    log "Backup do Coolify extraído em $OUT (nada foi sobrescrito)."
    cat <<MSG
Restauração do Coolify (manual — procedimento oficial de migração/backup):
  1. Instale o Coolify (homelab-setup.sh) e pare-o:   docker stop coolify
  2. Restaure o banco:
       docker cp $OUT/coolify-db.dump coolify-db:/tmp/coolify.dump
       docker exec coolify-db pg_restore --clean --if-exists --no-acl --no-owner -U coolify -d coolify /tmp/coolify.dump
  3. Copie a APP_KEY antiga ($OUT/data/coolify/source/.env) para APP_PREVIOUS_KEYS
     em /data/coolify/source/.env (sem ela os segredos do banco não abrem)
  4. Copie chaves SSH e proxy:  $OUT/data/coolify/{ssh,proxy}  →  /data/coolify/
  5. Suba de novo:  cd /data/coolify/source && docker compose up -d
Documentação: https://coolify.io/docs/knowledge-base/how-to/backup-restore-coolify
MSG
    ;;

  config)
    need config.tar.gz
    OUT="/tmp/homelab-config-$(basename "$SRC")"
    rm -rf "$OUT"; mkdir -p "$OUT"; chmod 700 "$OUT"
    tar xzf "$SRC/config.tar.gz" -C "$OUT"
    log "Configurações extraídas em $OUT (nada foi sobrescrito)."
    echo "Compare e copie o que precisar, por exemplo:"
    echo "  sudo diff -ru $OUT/etc/ufw /etc/ufw"
    echo "  sudo cp $OUT/opt/homelab/infra/.env $INFRA/.env"
    ;;

  *) usage ;;
esac
