#!/usr/bin/env bash
# shellcheck source=/dev/null
[[ -r "${HOMELAB_CONF:-/etc/homelab.conf}" ]] && . "${HOMELAB_CONF:-/etc/homelab.conf}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
BACKUP_GROUP="${BACKUP_GROUP:-root}"
# Prepara um SSD externo como destino da cópia dos backups do homelab.
#
#   sudo backup-disk-setup.sh                     # lista os discos (não altera nada)
#   sudo backup-disk-setup.sh /dev/sdX --format   # APAGA o disco, cria GPT + ext4 e configura
#   sudo backup-disk-setup.sh /dev/sdX1           # usa uma partição Linux existente (sem apagar)
#
# Monta por UUID em /mnt/backup-ssd (fstab com nofail: o servidor inicia mesmo sem o disco),
# grava BACKUP_EXTERNAL_* no .env e copia os backups locais existentes.
set -Eeuo pipefail

INFRA="$HOMELAB_DIR/infra"
ENV_FILE="$INFRA/.env"
MNT="${BACKUP_MOUNT:-/mnt/backup-ssd}"
LABEL="HOMELAB-BKP"
FSTAB_MARK="# homelab-backup-ssd (gerenciado por backup-disk-setup.sh)"

log() { echo "==> $*"; }
die() { echo "✘ $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo $0 $*"
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE não encontrado — rode o homelab-setup.sh antes"

set_env() {
  if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi
}
disk_of() { { lsblk -lnpso NAME,TYPE "$1" 2>/dev/null || true; } | awk '$2=="disk"||$2=="loop"{print $1; exit}'; }
is_whole_disk() { [[ "$(lsblk -dno TYPE "$1")" =~ ^(disk|loop)$ ]]; }

ROOT_DISK="$(disk_of "$(findmnt -n -o SOURCE /)")"

usage() {
  echo
  echo "Uso:"
  echo "  sudo $0 /dev/sdX --format    # apaga o disco e prepara (ext4)"
  echo "  sudo $0 /dev/sdX1            # usa partição ext4/xfs/btrfs existente"
}

list_disks() {
  echo "Discos encontrados:"
  local name rest
  while read -r name rest; do
    if [[ "$name" == "$ROOT_DISK" ]]; then
      echo "  $name $rest   ← DISCO DO SISTEMA (não use)"
    else
      echo "  $name $rest"
    fi
  done < <(lsblk -dpno NAME,SIZE,TRAN,MODEL -e 7,11)
  echo
  lsblk -po NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS -e 7,11
}

DEV=""; FORMAT=0
for arg in "$@"; do
  case "$arg" in
    --format) FORMAT=1 ;;
    /dev/*)   DEV="$arg" ;;
    *) die "Argumento inválido: $arg" ;;
  esac
done

if [[ -z "$DEV" ]]; then list_disks; usage; exit 0; fi
[[ -b "$DEV" ]] || die "$DEV não é um dispositivo de bloco"
[[ "$(disk_of "$DEV")" != "$ROOT_DISK" ]] || die "$DEV pertence ao disco do sistema ($ROOT_DISK)"

# Re-execução: libera o ponto de montagem atual
if mountpoint -q "$MNT"; then umount "$MNT" || die "Não foi possível desmontar $MNT (em uso?)"; fi

if (( FORMAT )); then
  is_whole_disk "$DEV" || die "--format exige o disco inteiro (ex.: /dev/sdb), não uma partição"
  if lsblk -nro MOUNTPOINTS "$DEV" | grep -q .; then
    die "Há partições de $DEV montadas (automount?). Desmonte antes: lsblk $DEV"
  fi
  echo
  lsblk -po NAME,SIZE,FSTYPE,LABEL,MODEL "$DEV"
  echo
  echo "⚠️  TODOS os dados de $DEV serão APAGADOS."
  read -rp "Para confirmar, digite o caminho do disco ($DEV): " answer
  [[ "$answer" == "$DEV" ]] || die "Cancelado"

  log "Criando tabela GPT e partição ext4..."
  wipefs -a "$DEV" >/dev/null
  parted -s "$DEV" mklabel gpt mkpart homelab-backup ext4 0% 100%
  partprobe "$DEV" 2>/dev/null || true
  udevadm settle 2>/dev/null || sleep 2
  PART="$(lsblk -lnpo NAME,TYPE "$DEV" | awk '$2=="part"{print $1; exit}')"
  [[ -n "$PART" && -b "$PART" ]] || die "Partição não encontrada após o particionamento"
  mkfs.ext4 -F -q -L "$LABEL" -m 0 "$PART"
else
  PART="$DEV"
  if is_whole_disk "$DEV"; then
    PART="$(lsblk -lnpo NAME,TYPE "$DEV" | awk '$2=="part"{print $1; exit}')"
    [[ -n "$PART" ]] || die "$DEV não tem partições. Use --format para preparar o disco."
  fi
  if lsblk -nro MOUNTPOINTS "$PART" | grep -q .; then
    die "$PART está montada em $(lsblk -nro MOUNTPOINTS "$PART"). Desmonte antes: sudo umount $PART"
  fi
fi

FSTYPE="$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)"
case "$FSTYPE" in
  ext4|xfs|btrfs) ;;
  *) die "$PART tem sistema de arquivos '${FSTYPE:-nenhum}'. Os backups exigem ext4/xfs/btrfs (permissões e links). Use --format." ;;
esac
UUID="$(blkid -s UUID -o value "$PART")"
[[ -n "$UUID" ]] || die "UUID de $PART não encontrado"

log "Configurando montagem automática (fstab, por UUID)..."
mkdir -p "$MNT"
cp -a /etc/fstab /etc/fstab.homelab.bak
awk -v m="$MNT" -v mark="$FSTAB_MARK" '$0 != mark && $2 != m' /etc/fstab.homelab.bak > /etc/fstab
printf '%s\nUUID=%s %s %s defaults,noatime,nofail,x-systemd.device-timeout=10s 0 2\n' \
  "$FSTAB_MARK" "$UUID" "$MNT" "$FSTYPE" >> /etc/fstab
if ! findmnt --verify --tab-file /etc/fstab >/dev/null 2>&1; then
  cp -a /etc/fstab.homelab.bak /etc/fstab
  die "fstab inválido — arquivo original restaurado"
fi
systemctl daemon-reload 2>/dev/null || true
mount "$MNT" || { cp -a /etc/fstab.homelab.bak /etc/fstab; systemctl daemon-reload 2>/dev/null || true; die "Falha ao montar — fstab restaurado"; }
mountpoint -q "$MNT" || die "$MNT não ficou montado"

EXT_DIR="$MNT/homelab"
install -d -m 750 -o root -g "$BACKUP_GROUP" "$EXT_DIR"
echo ok > "$EXT_DIR/.write-test" && rm -f "$EXT_DIR/.write-test" || die "Sem permissão de escrita em $EXT_DIR"

set_env BACKUP_EXTERNAL_MOUNT "$MNT"
set_env BACKUP_EXTERNAL_DIR "$EXT_DIR"
grep -q '^BACKUP_EXTERNAL_KEEP_DAYS=' "$ENV_FILE" || set_env BACKUP_EXTERNAL_KEEP_DAYS 30
log "Configuração gravada em $ENV_FILE (BACKUP_EXTERNAL_*)"

log "Copiando backups locais existentes para o SSD..."
"$HOMELAB_DIR/scripts/backup.sh" --sync-external || echo "  ! cópia inicial falhou — veja a mensagem acima"

echo
echo "✔ SSD externo pronto"
echo "  Partição ...... $PART ($FSTYPE, UUID=$UUID)"
echo "  Montado em .... $MNT  →  backups em $EXT_DIR"
echo "  Espaço ........ $(df -h --output=size,avail "$MNT" | tail -1 | awk '{print $2" livres de "$1}')"
echo "  Retenção ...... $(grep '^BACKUP_EXTERNAL_KEEP_DAYS=' "$ENV_FILE" | cut -d= -f2) dias (BACKUP_EXTERNAL_KEEP_DAYS no .env)"
echo "  O backup diário (03:00) copia para o SSD automaticamente."
