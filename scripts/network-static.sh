#!/usr/bin/env bash
# Fixa o IP do homelab na rede local (netplan), com reversão automática de segurança.
#
#   sudo network-static.sh                                   # mostra a rede atual e uma sugestão
#   sudo network-static.sh 192.168.101.50/24                 # aplica (gateway e DNS detectados)
#   sudo network-static.sh 192.168.101.50/24 --gateway 192.168.101.1 --dns "1.1.1.1 8.8.8.8"
#   sudo network-static.sh --confirm                         # confirma (cancela a reversão)
#   sudo network-static.sh --dhcp                            # volta para DHCP
#
# Após aplicar, você tem 5 minutos para conectar no IP novo e rodar --confirm.
# Sem confirmação, a configuração anterior volta sozinha (não fica trancado para fora).
set -Eeuo pipefail

NETPLAN_FILE="/etc/netplan/90-homelab-static.yaml"
BACKUP_FILE="/etc/netplan/.90-homelab-static.yaml.prev"
REVERT_UNIT="homelab-net-revert"
REVERT_SECONDS=300

log() { echo "==> $*"; }
die() { echo "✘ $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo $0 $*"

IFACE=""; ADDR=""; GW=""; DNS=""; MODE="apply"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) MODE="confirm" ;;
    --dhcp)    MODE="dhcp" ;;
    --gateway) GW="${2:?informe o gateway}"; shift ;;
    --dns)     DNS="${2:?informe os DNS}"; shift ;;
    --iface)   IFACE="${2:?informe a interface}"; shift ;;
    */*)       ADDR="$1" ;;
    *) die "Argumento inválido: $1 (use IP/prefixo, ex.: 192.168.101.50/24)" ;;
  esac
  shift
done

IFACE="${IFACE:-$(ip -4 route show default | awk '{print $5; exit}')}"
[[ -n "$IFACE" ]] || die "Interface com rota padrão não encontrada — use --iface"
CUR_ADDR="$(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')"
CUR_GW="$(ip -4 route show default dev "$IFACE" | awk '{print $3; exit}')"
CUR_DNS="$(resolvectl dns "$IFACE" 2>/dev/null | cut -d: -f2- | xargs || true)"
KIND="ethernets"; [[ -d "/sys/class/net/$IFACE/wireless" ]] && KIND="wifis"

restart_hint() {
  echo "  Depois atualize a configuração do homelab e o certificado da LAN com o IP novo:"
  echo "    cd ~/homelab && sudo ./homelab-setup.sh"
  echo "    sudo /opt/homelab/scripts/homelab-ca.sh issue"
}

case "$MODE" in
  confirm)
    if systemctl is-active --quiet "$REVERT_UNIT.timer" 2>/dev/null; then
      systemctl stop "$REVERT_UNIT.timer" "$REVERT_UNIT.service" 2>/dev/null || true
      rm -f "$BACKUP_FILE"
      echo "✔ Configuração de rede confirmada: $CUR_ADDR em $IFACE"
      restart_hint
    else
      echo "Nenhuma alteração pendente de confirmação."
    fi
    exit 0
    ;;
  dhcp)
    [[ -f "$NETPLAN_FILE" ]] || { echo "O IP já é obtido por DHCP (nenhum $NETPLAN_FILE)."; exit 0; }
    rm -f "$NETPLAN_FILE"
    netplan apply
    echo "✔ Voltou para DHCP em $IFACE. IP atual: $(ip -4 -o addr show dev "$IFACE" | awk '{print $4; exit}')"
    restart_hint
    exit 0
    ;;
esac

if [[ -z "$ADDR" ]]; then
  echo "Rede atual"
  echo "  Interface ... $IFACE ($([[ $KIND == wifis ]] && echo Wi-Fi || echo cabo))"
  echo "  Endereço .... ${CUR_ADDR:-?}"
  echo "  Gateway ..... ${CUR_GW:-?}"
  echo "  DNS ......... ${CUR_DNS:-?}"
  echo "  Modo ........ $([[ -f $NETPLAN_FILE ]] && echo "fixo ($NETPLAN_FILE)" || echo DHCP)"
  echo
  echo "Para fixar, escolha um IP FORA da faixa de DHCP do roteador (ex.: final .200–.250)."
  echo "Manter o IP atual só é seguro se o roteador nunca o entregar a outro aparelho."
  echo
  echo "  sudo $0 ${CUR_ADDR:-192.168.x.y/24}"
  exit 0
fi

GW="${GW:-$CUR_GW}"
[[ -n "$GW" ]] || die "Gateway não detectado — use --gateway"
DNS="${DNS:-${CUR_DNS:-$GW 1.1.1.1}}"

# Validação: formato, mesma sub-rede do gateway, não é rede/broadcast
python3 - "$ADDR" "$GW" $DNS <<'PY' || die "Endereço inválido"
import ipaddress, sys
iface = ipaddress.ip_interface(sys.argv[1]); gw = ipaddress.ip_address(sys.argv[2])
assert iface.version == 4, "somente IPv4"
assert gw in iface.network, f"gateway {gw} fora da rede {iface.network}"
assert iface.ip not in (iface.network.network_address, iface.network.broadcast_address), "endereço de rede/broadcast"
for d in sys.argv[3:]: ipaddress.ip_address(d)
PY

NEW_IP="${ADDR%/*}"
if [[ "$NEW_IP" != "${CUR_ADDR%/*}" ]]; then
  log "Verificando se $NEW_IP já está em uso na rede..."
  if ! arping -D -q -c 3 -w 4 -I "$IFACE" "$NEW_IP"; then
    die "$NEW_IP já responde na rede (outro aparelho está usando). Escolha outro."
  fi
fi

DNS_YAML="$(printf '%s, ' $DNS)"; DNS_YAML="[${DNS_YAML%, }]"

log "Gerando $NETPLAN_FILE ($KIND/$IFACE → $ADDR, gw $GW, dns $DNS)"
[[ -f "$NETPLAN_FILE" ]] && cp -a "$NETPLAN_FILE" "$BACKUP_FILE" || rm -f "$BACKUP_FILE"
umask 077
cat > "$NETPLAN_FILE" <<YAML
# Gerado por network-static.sh — IP fixo do homelab (sobrepõe o DHCP dos outros arquivos)
network:
  version: 2
  ${KIND}:
    ${IFACE}:
      dhcp4: false
      addresses: [${ADDR}]
      routes:
        - to: default
          via: ${GW}
      nameservers:
        addresses: ${DNS_YAML}
YAML
chmod 600 "$NETPLAN_FILE"

if ! netplan generate 2>/tmp/netplan-err; then
  cat /tmp/netplan-err >&2
  if [[ -f "$BACKUP_FILE" ]]; then mv -f "$BACKUP_FILE" "$NETPLAN_FILE"; else rm -f "$NETPLAN_FILE"; fi
  die "Configuração do netplan inválida — nada foi aplicado"
fi

# cloud-init (Ubuntu Server) regrava a rede no boot; desativa só essa parte
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
  echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-homelab-disable-network-config.cfg
fi

# Reversão automática: sem --confirm em 5 min, volta a configuração anterior
REVERT_CMD="if [ -f $BACKUP_FILE ]; then mv -f $BACKUP_FILE $NETPLAN_FILE; else rm -f $NETPLAN_FILE; fi; netplan apply"
systemctl stop "$REVERT_UNIT.timer" "$REVERT_UNIT.service" 2>/dev/null || true
systemctl reset-failed "$REVERT_UNIT.service" 2>/dev/null || true
systemd-run --quiet --unit "$REVERT_UNIT" --on-active="$REVERT_SECONDS" /bin/sh -c "$REVERT_CMD"

log "Aplicando... (uma sessão SSH no IP antigo pode cair)"
netplan apply

echo
echo "✔ IP $ADDR aplicado em $IFACE."
echo "  ⚠️  Confirme em até $(( REVERT_SECONDS / 60 )) minutos, conectando no IP NOVO:"
echo "      ssh $(logname 2>/dev/null || echo eduardo)@${NEW_IP}"
echo "      sudo $0 --confirm"
echo "  Sem confirmação, a rede volta sozinha para a configuração anterior."
