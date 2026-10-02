#!/usr/bin/env bash
# =============================================================================
#  homelab-setup.sh — Provisionamento do homelab (ThinkPad L14 + Ubuntu Server)
#
#  Base:     Ubuntu servidor | SSH + fail2ban | UFW (+Docker) | mDNS | tampa fechada/TLP
#  Dados:    Docker Engine + Compose | rede "devnet" | MySQL 8.4 + Adminer
#            Redis 7 + RedisInsight | RabbitMQ 4 + Management | volumes persistentes
#  Projetos: Coolify (PaaS self-hosted: deploy do GitHub, domínios, HTTPS, logs)
#  Extras:   CA local p/ HTTPS na LAN | backup diário + SSD externo | IP fixo
#            preparação GitHub Actions (self-hosted)
#
#  Uso:   git clone https://github.com/eduferrari/homelab.git && cd homelab
#         sudo ./homelab-setup.sh
#  Idempotente: pode ser executado novamente com segurança.
# =============================================================================
set -Eeuo pipefail

# ------------------------------- Configuração --------------------------------
# Todas as variáveis podem ser sobrescritas via ambiente:
#   sudo HOMELAB_USER=eduardo INSTALL_TLP=false ./homelab-setup.sh
HOMELAB_USER="${HOMELAB_USER:-${SUDO_USER:-}}"
HOMELAB_DIR="${HOMELAB_DIR:-/opt/homelab}"
TIMEZONE="${TIMEZONE:-America/Sao_Paulo}"
DOCKER_NETWORK="${DOCKER_NETWORK:-devnet}"

# SSH: auto = desativa login por senha somente se o usuário já tiver authorized_keys
DISABLE_SSH_PASSWORD="${DISABLE_SSH_PASSWORD:-auto}"   # auto | true | false
SSH_PORT="${SSH_PORT:-22}"

# Modo headless: remove o boot gráfico se Ubuntu Desktop estiver instalado
HEADLESS="${HEADLESS:-true}"

# Saúde da bateria (ThinkPad): carrega só entre 75% e 80%, já que fica sempre na tomada
INSTALL_TLP="${INSTALL_TLP:-true}"
BATTERY_START_THRESHOLD="${BATTERY_START_THRESHOLD:-75}"
BATTERY_STOP_THRESHOLD="${BATTERY_STOP_THRESHOLD:-80}"

# Desliga o backlight do console após N segundos (0 = nunca)
CONSOLE_BLANK_SECONDS="${CONSOLE_BLANK_SECONDS:-60}"

# GitHub Actions self-hosted runner (só prepara; o registro exige token)
PREPARE_GH_RUNNER="${PREPARE_GH_RUNNER:-true}"
GH_RUNNER_USER="${GH_RUNNER_USER:-gh-runner}"
GH_RUNNER_DIR="${GH_RUNNER_DIR:-/opt/actions-runner}"

# Coolify (gerenciador de projetos). Instala só se as portas 80, 443, 8000 e 8080 estiverem livres.
INSTALL_COOLIFY="${INSTALL_COOLIFY:-true}"
COOLIFY_ADMIN_EMAIL="${COOLIFY_ADMIN_EMAIL:-admin@homelab.local}"
COOLIFY_AUTOUPDATE="${COOLIFY_AUTOUPDATE:-false}"   # atualizações manuais (mais previsível)

# IP público fixo do provedor (informativo: status e README)
PUBLIC_IP="${PUBLIC_IP:-}"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

LOG_FILE="/var/log/homelab-setup.log"

# --------------------------------- Helpers -----------------------------------
C_RESET=$'\e[0m'; C_BLUE=$'\e[1;34m'; C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'
step() { echo -e "\n${C_BLUE}==> $*${C_RESET}"; }
ok()   { echo -e "${C_GREEN}  ✔ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}  ! $*${C_RESET}"; }
die()  { echo -e "${C_RED}  ✘ $*${C_RESET}" >&2; exit 1; }

trap 'die "Falha na linha $LINENO (comando: $BASH_COMMAND). Veja $LOG_FILE"' ERR

gen_secret() { openssl rand -hex 16; }
# Senha aceita pelas regras do Coolify (maiúscula, minúscula, número e símbolo)
gen_password() { echo "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)Aa1-"; }

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" >/dev/null
}

# ------------------------------- Pré-checagens -------------------------------
[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo ./homelab-setup.sh"
# Executado de dentro de "sudo su"/"sudo -i", o SUDO_USER vira root: tenta o dono da sessão
if [[ -z "$HOMELAB_USER" || "$HOMELAB_USER" == "root" ]]; then
  HOMELAB_USER="$(logname 2>/dev/null || true)"
fi
[[ -n "$HOMELAB_USER" && "$HOMELAB_USER" != "root" ]] || \
  die "Não foi possível detectar seu usuário (não use root). Rode a partir do seu usuário: sudo ./homelab-setup.sh  — ou: sudo HOMELAB_USER=<usuario> ./homelab-setup.sh"
id "$HOMELAB_USER" &>/dev/null || die "Usuário '$HOMELAB_USER' não existe."

# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Este script é para Ubuntu (detectado: ${ID:-desconhecido})."
case "${VERSION_ID:-}" in
  22.04|24.04) ;;
  *) warn "Ubuntu ${VERSION_ID:-?} não testado (recomendado: 24.04 LTS). Continuando..." ;;
esac
[[ "$(uname -m)" == "x86_64" ]] || warn "Arquitetura $(uname -m) — o runner do GitHub será baixado para x64."

USER_HOME="$(getent passwd "$HOMELAB_USER" | cut -d: -f6)"
[[ -d "$SCRIPT_DIR/scripts" ]] || die "Pasta scripts/ não encontrada ao lado do setup. Rode a partir do clone do repositório."

exec > >(tee -a "$LOG_FILE") 2>&1
echo "===== homelab-setup $(date '+%F %T') — usuário: $HOMELAB_USER ====="

# ============================ 1. Sistema base ================================
step "1/13 Atualizando sistema e instalando pacotes base"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq >/dev/null
apt_install ca-certificates curl gnupg lsb-release git jq unzip zip htop btop tmux \
  net-tools dnsutils iputils-ping vim nano openssl software-properties-common \
  unattended-upgrades apt-transport-https bash-completion \
  tcpdump netcat-openbsd avahi-daemon libnss-mdns rsync parted iputils-arping
ok "Pacotes base instalados (inclui tcpdump e netcat para diagnóstico)"

# mDNS: o notebook responde como <hostname>.local na LAN, sem depender de IP fixo
# Anuncia só IPv4: pelo IPv6 as portas dos containers caem no UFW (timeout),
# e os clientes esperariam esse timeout antes de tentar o IPv4.
AVAHI_CONF=/etc/avahi/avahi-daemon.conf
if [[ -f "$AVAHI_CONF" ]]; then
  sed -i 's/^#\?use-ipv6=.*/use-ipv6=no/; s/^#\?publish-aaaa-on-ipv4=.*/publish-aaaa-on-ipv4=no/' "$AVAHI_CONF"
fi
systemctl enable avahi-daemon >/dev/null 2>&1
systemctl restart avahi-daemon
ok "mDNS ativo: acesse por $(hostname).local"

timedatectl set-timezone "$TIMEZONE"
ok "Timezone: $TIMEZONE"

# Atualizações automáticas de segurança
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
ok "Unattended-upgrades (segurança) ativado"

# Ajustes de kernel para servidor + Redis + ferramentas de dev
cat > /etc/sysctl.d/99-homelab.conf <<'EOF'
vm.swappiness = 10
vm.overcommit_memory = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF
sysctl --system >/dev/null
ok "sysctl ajustado (swappiness, overcommit p/ Redis, inotify)"

# ============================ 2. Modo servidor ===============================
step "2/13 Preparando Ubuntu para uso como servidor"
if [[ "$HEADLESS" == "true" && "$(systemctl get-default)" == "graphical.target" ]]; then
  systemctl set-default multi-user.target >/dev/null
  ok "Boot alterado para modo texto (multi-user.target) — economiza RAM"
else
  ok "Target de boot: $(systemctl get-default)"
fi

# ======================= 3. Tampa fechada / energia ==========================
step "3/13 Configurando notebook para ficar ligado com a tampa fechada"
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-homelab-lid.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1
ok "Tampa ignorada e suspensão/hibernação bloqueadas"

if [[ "$CONSOLE_BLANK_SECONDS" -gt 0 ]] && ! grep -q "consoleblank=" /etc/default/grub; then
  sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 consoleblank=${CONSOLE_BLANK_SECONDS}\"/" /etc/default/grub
  update-grub >/dev/null 2>&1
  ok "Tela do console desliga após ${CONSOLE_BLANK_SECONDS}s (efetivo após reboot)"
fi

if [[ "$INSTALL_TLP" == "true" ]]; then
  apt_install tlp
  systemctl mask power-profiles-daemon >/dev/null 2>&1 || true
  mkdir -p /etc/tlp.d
  cat > /etc/tlp.d/01-homelab.conf <<EOF
# Homelab: notebook sempre na tomada — preserva a bateria
START_CHARGE_THRESH_BAT0=${BATTERY_START_THRESHOLD}
STOP_CHARGE_THRESH_BAT0=${BATTERY_STOP_THRESHOLD}
# Evita economia de energia que derruba rede/USB em servidor
WIFI_PWR_ON_AC=off
RUNTIME_PM_ON_AC=on
USB_AUTOSUSPEND=0
EOF
  systemctl enable --now tlp >/dev/null 2>&1
  tlp start >/dev/null 2>&1 || true
  ok "TLP ativo: bateria carrega entre ${BATTERY_START_THRESHOLD}% e ${BATTERY_STOP_THRESHOLD}%"
fi

# ================================ 4. SSH =====================================
step "4/13 Configurando SSH"
apt_install openssh-server
PASSWORD_AUTH="yes"
if [[ "$DISABLE_SSH_PASSWORD" == "true" ]]; then
  PASSWORD_AUTH="no"
elif [[ "$DISABLE_SSH_PASSWORD" == "auto" && -s "$USER_HOME/.ssh/authorized_keys" ]]; then
  PASSWORD_AUTH="no"
fi

# O Ubuntu lê sshd_config.d em ordem alfabética e a PRIMEIRA ocorrência vence.
# Por isso o prefixo 00- (antes do 50-cloud-init.conf, que força PasswordAuthentication yes).
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-homelab.conf"
rm -f /etc/ssh/sshd_config.d/99-homelab.conf   # nome usado em versões anteriores do script

# No Ubuntu 24.04 o SSH é ativado por socket: /run/sshd só existe depois que
# o serviço sobe, e sem ele o "sshd -t" falha com "Missing privilege separation directory".
install -d -m 0755 /run/sshd

# O Coolify gerencia o próprio host por SSH como root (chave gerada por ele), a partir dos
# seus containers. Root: só com chave e só das redes Docker/loopback — nunca da LAN.
ROOT_LOGIN="no"; ALLOW_USERS="${HOMELAB_USER}"
if [[ "$INSTALL_COOLIFY" == "true" ]]; then
  ROOT_LOGIN="prohibit-password"
  ALLOW_USERS="${HOMELAB_USER} root@10.0.0.0/8 root@172.16.0.0/12 root@127.0.0.1"
fi

cat > "$SSHD_DROPIN" <<EOF
Port ${SSH_PORT}
PermitRootLogin ${ROOT_LOGIN}
PasswordAuthentication ${PASSWORD_AUTH}
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers ${ALLOW_USERS}
EOF
if ! SSHD_CHECK="$(/usr/sbin/sshd -t 2>&1)"; then
  rm -f "$SSHD_DROPIN"   # não deixa o SSH com configuração quebrada
  die "Configuração do SSH inválida (arquivo revertido):
$SSHD_CHECK"
fi

# 24.04+: troca a ativação por socket pelo serviço clássico (sempre escutando,
# respeita Port do sshd_config e evita "Connection refused" após reinícios)
if systemctl list-unit-files ssh.socket 2>/dev/null | grep -q '^ssh.socket'; then
  systemctl disable --now ssh.socket >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/ssh.service.d/00-socket.conf
  systemctl daemon-reload
fi
systemctl enable ssh.service >/dev/null 2>&1
if ! systemctl restart ssh.service; then
  # fallback: algumas instalações ainda dependem do socket — reativa para não perder o acesso
  warn "ssh.service não subiu sozinho; reativando ssh.socket"
  systemctl enable --now ssh.socket >/dev/null 2>&1 || true
  systemctl restart ssh.socket || true
fi
sleep 1
ss -tln | grep -q ":${SSH_PORT} " || die "sshd não está escutando na porta ${SSH_PORT} — veja: journalctl -u ssh -n 30"
ok "SSH na porta ${SSH_PORT} | usuário: ${HOMELAB_USER} | root: $([[ $ROOT_LOGIN == no ]] && echo bloqueado || echo 'só chave, só redes Docker (Coolify)') | senha: ${PASSWORD_AUTH}"
if [[ "$PASSWORD_AUTH" == "yes" ]]; then
  warn "Login por senha ainda ativo. Copie sua chave (ssh-copy-id) e rode novamente com DISABLE_SSH_PASSWORD=true"
fi

apt_install fail2ban
cat > /etc/fail2ban/jail.d/homelab.local <<EOF
[DEFAULT]
# nunca bane a própria LAN (evita se trancar para fora do homelab)
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16

[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl enable --now fail2ban >/dev/null 2>&1
systemctl restart fail2ban
ok "fail2ban protegendo o SSH"

# ============================== 5. Docker ====================================
step "5/13 Instalando Docker Engine + Docker Compose (repositório oficial)"
if ! command -v docker &>/dev/null || ! docker compose version &>/dev/null; then
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y -qq "$pkg" >/dev/null 2>&1 || true
  done
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

mkdir -p /etc/docker
# default-address-pools igual ao padrão do Coolify: com o pool já definido, o instalador
# dele mantém este arquivo (e o live-restore) em vez de reescrevê-lo.
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "default-address-pools": [ { "base": "10.0.0.0/8", "size": 24 } ]
}
EOF
systemctl enable docker containerd >/dev/null 2>&1
systemctl restart docker
usermod -aG docker "$HOMELAB_USER"
ok "$(docker --version)"
ok "$(docker compose version)"
ok "Usuário $HOMELAB_USER adicionado ao grupo docker"

# ============================== 6. Firewall ==================================
step "6/13 Configurando firewall UFW (+ integração com Docker)"
apt_install ufw
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw limit "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
# SSH vindo dos containers do Coolify: sem rate-limit (ele abre várias conexões seguidas)
for net in 10.0.0.0/8 172.16.0.0/12; do
  ufw insert 1 allow proto tcp from "$net" to any port "${SSH_PORT}" comment 'SSH (Coolify)' >/dev/null 2>&1 || true
done
# Remove regras de versões anteriores (Caddy na rede do host, painel e acesso público do Caddy)
for net in 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 100.64.0.0/10; do
  ufw delete allow proto tcp from "$net" to any port 80,443,8081:8089,9000:9002,9090 >/dev/null 2>&1 || true
  ufw delete allow proto udp from "$net" to any port 443 >/dev/null 2>&1 || true
done
for r in 80/tcp 443/tcp 443/udp; do ufw delete allow "$r" >/dev/null 2>&1 || true; done
ufw delete allow from 172.16.0.0/12 to any port 9091 proto tcp >/dev/null 2>&1 || true
# mDNS (resolução de <hostname>.local) — apenas redes privadas
for net in 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12; do
  ufw allow from "$net" to any port 5353 proto udp comment 'mDNS' >/dev/null
done

# O Docker publica portas direto no iptables e IGNORA as regras do UFW.
# Este bloco (padrão ufw-docker) libera as portas dos containers apenas
# para redes privadas (LAN/VPN) e bloqueia acesso vindo da internet.
if ! grep -q "BEGIN UFW AND DOCKER" /etc/ufw/after.rules; then
  cat >> /etc/ufw/after.rules <<'EOF'

# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16
-A DOCKER-USER -j RETURN -s 100.64.0.0/10

-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN

-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 172.16.0.0/12

-A DOCKER-USER -j RETURN

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END UFW AND DOCKER
EOF
  ok "Regras UFW+Docker adicionadas em /etc/ufw/after.rules"
fi

ufw --force enable >/dev/null
ufw reload >/dev/null
systemctl restart docker
ok "UFW ativo: entrada negada por padrão, SSH com rate-limit, mDNS na LAN; containers só na LAN"


# ======================= 7. Estrutura, configuração e limpeza ================
step "7/13 Estrutura de diretórios e limpeza de versões anteriores"
INFRA_DIR="$HOMELAB_DIR/infra"
mkdir -p "$INFRA_DIR"/mysql/{conf.d,init} "$HOMELAB_DIR"/{apps,backups,scripts} \
         "$USER_HOME"/projects/{apps,libs,sandbox}
install -d -m 700 -o root -g root "$HOMELAB_DIR/ca"

chown -R "$HOMELAB_USER":"$HOMELAB_USER" "$USER_HOME/projects"
chown "$HOMELAB_USER":docker "$HOMELAB_DIR"
chown -R "$HOMELAB_USER":docker "$INFRA_DIR" "$HOMELAB_DIR/apps" "$HOMELAB_DIR/scripts"
chmod 2775 "$HOMELAB_DIR/apps"
# Backups contêm segredos (.env, CA): só root grava; só o seu usuário lê (para copiar ao Mac)
BACKUP_GROUP="$(id -gn "$HOMELAB_USER")"
chown -R root:"$BACKUP_GROUP" "$HOMELAB_DIR/backups"
chmod 750 "$HOMELAB_DIR/backups"

# Configuração lida pelos scripts utilitários
cat > /etc/homelab.conf <<EOF
# Gerado por homelab-setup.sh
HOMELAB_DIR="${HOMELAB_DIR}"
HOMELAB_USER="${HOMELAB_USER}"
BACKUP_GROUP="${BACKUP_GROUP}"
GH_RUNNER_USER="${GH_RUNNER_USER}"
GH_RUNNER_DIR="${GH_RUNNER_DIR}"
EOF
chmod 644 /etc/homelab.conf

# --- Limpeza das versões anteriores (painel, Caddy da stack, Cockpit) — dados preservados
LEGACY_DIR="$HOMELAB_DIR/legacy/$(date +%F_%H%M%S)"
for d in caddy homepage portainer; do
  if [[ -d "$INFRA_DIR/$d" ]]; then
    mkdir -p "$LEGACY_DIR"; mv "$INFRA_DIR/$d" "$LEGACY_DIR/"
    warn "infra/$d movido para $LEGACY_DIR (não é mais usado)"
  fi
done
if [[ -f /etc/cockpit/cockpit.conf ]] && grep -q 'homelab-setup.sh' /etc/cockpit/cockpit.conf; then
  systemctl disable --now cockpit.socket >/dev/null 2>&1 || true
  rm -rf /etc/systemd/system/cockpit.socket.d /etc/cockpit/cockpit.conf
  apt-get purge -y -qq cockpit cockpit-storaged cockpit-packagekit cockpit-bridge cockpit-ws >/dev/null 2>&1 || true
  apt-get autoremove -y -qq >/dev/null 2>&1 || true
  systemctl daemon-reload
  ok "Cockpit removido"
fi
ok "Infra em $HOMELAB_DIR | projetos em $USER_HOME/projects | config em /etc/homelab.conf"

# ============================ 8. Rede Docker =================================
step "8/13 Criando rede Docker '$DOCKER_NETWORK'"
if ! docker network inspect "$DOCKER_NETWORK" &>/dev/null; then
  docker network create --driver bridge "$DOCKER_NETWORK" >/dev/null
  ok "Rede $DOCKER_NETWORK criada"
else
  ok "Rede $DOCKER_NETWORK já existe"
fi

# ======================= 9. Stack de dados (Compose) =========================
step "9/13 Gerando stack de dados (MySQL, Redis, RabbitMQ)"
ENV_FILE="$INFRA_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<EOF
# ==== Gerado por homelab-setup.sh em $(date '+%F %T') — NÃO versionar ====
TZ=${TIMEZONE}

# MySQL 8.4
MYSQL_PORT=3306
MYSQL_ROOT_PASSWORD=$(gen_secret)
MYSQL_DATABASE=appdb
MYSQL_USER=dev
MYSQL_PASSWORD=$(gen_secret)

# Adminer
ADMINER_PORT=8088

# Redis 7
REDIS_PORT=6379
REDIS_PASSWORD=$(gen_secret)

# RedisInsight
REDISINSIGHT_PORT=5540

# RabbitMQ 4
RABBITMQ_PORT=5672
RABBITMQ_UI_PORT=15672
RABBITMQ_DEFAULT_USER=admin
RABBITMQ_DEFAULT_PASS=$(gen_secret)
EOF
  ok "Credenciais geradas em $ENV_FILE"
else
  ok "$ENV_FILE já existe — credenciais preservadas"
fi

set_env() {
  if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi
}
# A porta 8080 passa a ser do painel do Traefik (proxy do Coolify): Adminer vai para 8088
if grep -q '^ADMINER_PORT=8080$' "$ENV_FILE"; then
  set_env ADMINER_PORT 8088
  warn "Adminer mudou de porta: 8080 → 8088 (a 8080 é do proxy do Coolify)"
fi
# Chaves de versões anteriores que não são mais usadas
sed -i -E '/^(CADDY_APP_PORTS|PORTAINER_ADMIN_PASSWORD|UPTIME_KUMA_PUSH_TOKEN|PUBLIC_ACCESS)=/d;
           /^# (Caddy \(proxy reverso|Painel de administração|Token do monitor|Acesso da internet ao Caddy|Acesso público \(public)/d' "$ENV_FILE"
grep -q '^BACKUP_KEEP_DAYS=' "$ENV_FILE" || printf '\n# Backup (dias de retenção)\nBACKUP_KEEP_DAYS=7\n' >> "$ENV_FILE"
grep -q '^HOMELAB_CA_EXTRA_NAMES=' "$ENV_FILE" || \
  printf '\n# Nomes extras no certificado da LAN (separados por espaço) — homelab-ca.sh\nHOMELAB_CA_EXTRA_NAMES=\n' >> "$ENV_FILE"
if [[ "$INSTALL_COOLIFY" == "true" ]] && ! grep -q '^COOLIFY_ADMIN_PASSWORD=' "$ENV_FILE"; then
  printf '\n# Coolify — admin criado na instalação (usuário: admin)\nCOOLIFY_ADMIN_EMAIL=%s\nCOOLIFY_ADMIN_PASSWORD=%s\n' \
    "$COOLIFY_ADMIN_EMAIL" "$(gen_password)" >> "$ENV_FILE"
fi
set_env HOMELAB_HOST "$(hostname).local"
set_env HOMELAB_IP "$(hostname -I | awk '{print $1}')"
[[ -n "$PUBLIC_IP" ]] && set_env HOMELAB_PUBLIC_IP "$PUBLIC_IP"
chown "$HOMELAB_USER":docker "$ENV_FILE"
chmod 640 "$ENV_FILE"

cat > "$INFRA_DIR/mysql/conf.d/homelab.cnf" <<'EOF'
[mysqld]
character-set-server = utf8mb4
collation-server     = utf8mb4_0900_ai_ci
skip-name-resolve
max_connections      = 200
innodb_buffer_pool_size = 512M
EOF
chmod 644 "$INFRA_DIR/mysql/conf.d/homelab.cnf"

cat > "$INFRA_DIR/docker-compose.yml" <<'EOF'
name: homelab

services:
  mysql:
    image: mysql:8.4
    container_name: mysql
    hostname: mysql
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    ports:
      - "${MYSQL_PORT}:3306"
    volumes:
      - mysql_data:/var/lib/mysql
      - ./mysql/conf.d:/etc/mysql/conf.d:ro
      - ./mysql/init:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\"$$MYSQL_ROOT_PASSWORD\" --silent"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    networks: [devnet]

  adminer:
    image: adminer:latest
    container_name: adminer
    restart: unless-stopped
    environment:
      ADMINER_DEFAULT_SERVER: mysql
      ADMINER_DESIGN: dracula
    ports:
      - "${ADMINER_PORT}:8080"
    depends_on:
      mysql:
        condition: service_healthy
    networks: [devnet]

  redis:
    image: redis:7-alpine
    container_name: redis
    hostname: redis
    restart: unless-stopped
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD}
    command: ["sh", "-c", "exec redis-server --appendonly yes --requirepass \"$$REDIS_PASSWORD\""]
    ports:
      - "${REDIS_PORT}:6379"
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$$REDIS_PASSWORD\" --no-auth-warning ping | grep -q PONG"]
      interval: 10s
      timeout: 3s
      retries: 5
    networks: [devnet]

  redisinsight:
    image: redis/redisinsight:latest
    container_name: redisinsight
    restart: unless-stopped
    environment:
      RI_ACCEPT_TERMS_AND_CONDITIONS: "true"
      RI_REDIS_HOST: redis
      RI_REDIS_PORT: "6379"
      RI_REDIS_ALIAS: homelab-redis
      RI_REDIS_PASSWORD: ${REDIS_PASSWORD}
    ports:
      - "${REDISINSIGHT_PORT}:5540"
    volumes:
      - redisinsight_data:/data
    depends_on:
      redis:
        condition: service_healthy
    networks: [devnet]

  rabbitmq:
    image: rabbitmq:4-management
    container_name: rabbitmq
    hostname: rabbitmq          # fixo: o RabbitMQ grava os dados pelo nome do nó
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_DEFAULT_USER}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_DEFAULT_PASS}
    ports:
      - "${RABBITMQ_PORT}:5672"
      - "${RABBITMQ_UI_PORT}:15672"
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 15s
      timeout: 10s
      retries: 10
      start_period: 30s
    networks: [devnet]

volumes:
  mysql_data:
  redis_data:
  redisinsight_data:
  rabbitmq_data:

networks:
  devnet:
    external: true
EOF
chown "$HOMELAB_USER":docker "$INFRA_DIR/docker-compose.yml"
ok "docker-compose.yml gerado em $INFRA_DIR"

# ======================= 10. Subindo a stack de dados ========================
step "10/13 Baixando imagens e subindo MySQL, Redis e RabbitMQ"
cd "$INFRA_DIR"
docker compose pull -q
# --remove-orphans: remove containers de versões anteriores desta stack (Caddy, painel)
docker compose up -d --remove-orphans --wait --wait-timeout 240
ok "Stack de dados no ar"
docker compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'
LEGACY_VOLS="$(docker volume ls -q | grep -E '^homelab_(caddy_data|caddy_config|portainer_data|uptime_kuma_data)$' || true)"
[[ -n "$LEGACY_VOLS" ]] && warn "Volumes de versões anteriores mantidos (remova quando não precisar): $(echo $LEGACY_VOLS)"

# ================ 11. Scripts utilitários, backup e certificado ==============
step "11/13 Instalando scripts utilitários e agendamentos"
for f in "$SCRIPT_DIR"/scripts/*.sh; do
  install -m 750 -o "$HOMELAB_USER" -g docker "$f" "$HOMELAB_DIR/scripts/$(basename "$f")"
done
rm -f "$HOMELAB_DIR"/scripts/{caddy-reload.sh,caddy-ca.sh}   # versões anteriores
ok "Scripts em $HOMELAB_DIR/scripts: $(cd "$HOMELAB_DIR/scripts" && ls | tr '\n' ' ')"

# Backup diário às 03:00 (roda como root, log no journal, recupera execuções perdidas)
cat > /etc/systemd/system/homelab-backup.service <<EOF
[Unit]
Description=Backup do homelab (MySQL, Redis, RabbitMQ, Coolify, configurações) + cópia para SSD externo
Wants=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=${HOMELAB_DIR}/scripts/backup.sh
Nice=10
IOSchedulingClass=idle
EOF
cat > /etc/systemd/system/homelab-backup.timer <<'EOF'
[Unit]
Description=Backup diário do homelab

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Renovação semanal do certificado da LAN (reemite se faltar < 30 dias ou se o IP mudou)
cat > /etc/systemd/system/homelab-ca-renew.service <<EOF
[Unit]
Description=Renova o certificado HTTPS da LAN (CA do homelab)

[Service]
Type=oneshot
ExecStart=${HOMELAB_DIR}/scripts/homelab-ca.sh renew
EOF
cat > /etc/systemd/system/homelab-ca-renew.timer <<'EOF'
[Unit]
Description=Verificação semanal do certificado da LAN

[Timer]
OnCalendar=weekly
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now homelab-backup.timer homelab-ca-renew.timer >/dev/null 2>&1
ok "Agendado: backup diário (03:00) e renovação semanal do certificado da LAN"

# ============================== 12. Coolify ==================================
step "12/13 Coolify (gerenciador de projetos)"
COOLIFY_STATE="não instalado"
if [[ "$INSTALL_COOLIFY" != "true" ]]; then
  warn "Instalação do Coolify ignorada (INSTALL_COOLIFY=false)"
elif [[ -f /data/coolify/source/.env ]]; then
  COOLIFY_STATE="instalado"
  ok "Coolify já instalado (atualize pelo painel ou: curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash)"
else
  BUSY=()
  for p in 80 443 8000 8080; do ss -tlnH "sport = :$p" | grep -q . && BUSY+=("$p"); done
  if (( ${#BUSY[@]} )); then
    COOLIFY_STATE="pendente (portas ${BUSY[*]} em uso)"
    warn "Coolify NÃO instalado: portas em uso: ${BUSY[*]}"
    ss -tlnpH | grep -E ":($(IFS='|'; echo "${BUSY[*]}")) " | sed 's/^/    /' || true
    warn "Libere as portas (ex.: pare o mesafacil-caddy — veja 'Migração' no README) e rode o setup de novo."
  else
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/coolify-install.sh
    ROOT_USERNAME=admin \
    ROOT_USER_EMAIL="$(grep -m1 '^COOLIFY_ADMIN_EMAIL=' "$ENV_FILE" | cut -d= -f2-)" \
    ROOT_USER_PASSWORD="$(grep -m1 '^COOLIFY_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)" \
    AUTOUPDATE="$COOLIFY_AUTOUPDATE" \
      bash /tmp/coolify-install.sh
    rm -f /tmp/coolify-install.sh
    COOLIFY_STATE="instalado"
    ok "Coolify instalado"
  fi
fi
if [[ "$COOLIFY_STATE" == "instalado" ]]; then
  if [[ -s "$HOMELAB_DIR/ca/root.key" ]]; then
    "$HOMELAB_DIR/scripts/homelab-ca.sh" renew
  else
    warn "HTTPS na LAN: configure a CA — reaproveitar a do Caddy antigo:  sudo $HOMELAB_DIR/scripts/homelab-ca.sh import-caddy"
    warn "                                        ou criar uma nova:        sudo $HOMELAB_DIR/scripts/homelab-ca.sh init"
  fi
fi

# =================== 13. Preparação GitHub Actions ===========================
step "13/13 Preparando GitHub Actions self-hosted runner"
if [[ "$PREPARE_GH_RUNNER" == "true" ]]; then
  if ! id "$GH_RUNNER_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$GH_RUNNER_USER"
    ok "Usuário $GH_RUNNER_USER criado"
  fi
  usermod -aG docker "$GH_RUNNER_USER"
  mkdir -p "$GH_RUNNER_DIR"

  if [[ ! -f "$GH_RUNNER_DIR/config.sh" ]]; then
    RUNNER_VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
    [[ -n "$RUNNER_VERSION" && "$RUNNER_VERSION" != "null" ]] || die "Não foi possível obter a versão do runner"
    curl -fsSL -o /tmp/actions-runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
    tar -xzf /tmp/actions-runner.tar.gz -C "$GH_RUNNER_DIR"
    rm -f /tmp/actions-runner.tar.gz
    "$GH_RUNNER_DIR/bin/installdependencies.sh" >/dev/null
    ok "Runner v${RUNNER_VERSION} baixado em $GH_RUNNER_DIR"
  else
    ok "Runner já presente em $GH_RUNNER_DIR"
  fi
  chown -R "$GH_RUNNER_USER":"$GH_RUNNER_USER" "$GH_RUNNER_DIR"

  ok "Para registrar: sudo $HOMELAB_DIR/scripts/register-runner.sh <url> <token>"
else
  warn "Preparação do runner ignorada (PREPARE_GH_RUNNER=false)"
fi

# ================================ Resumo =====================================
IP="$(hostname -I | awk '{print $1}')"
HOST="$(hostname).local"
cat <<EOF

${C_GREEN}=====================================================================
  Homelab pronto!  ${HOST}  (IP na LAN: ${IP})
=====================================================================${C_RESET}
  SSH ............ ssh ${HOMELAB_USER}@${HOST} -p ${SSH_PORT}
  Coolify ........ http://${HOST}:8000   [${COOLIFY_STATE}]
                   admin: COOLIFY_ADMIN_EMAIL / COOLIFY_ADMIN_PASSWORD no .env
  Adminer ........ http://${HOST}:$(grep -m1 '^ADMINER_PORT=' "$ENV_FILE" | cut -d= -f2)   (servidor: mysql)
  RedisInsight ... http://${HOST}:5540
  RabbitMQ UI .... http://${HOST}:15672
  MySQL / Redis .. ${IP}:3306 / ${IP}:6379   |   RabbitMQ AMQP ${IP}:5672

  Credenciais .... sudo cat ${ENV_FILE}
  Status ......... ${HOMELAB_DIR}/scripts/status.sh
  HTTPS na LAN ... sudo ${HOMELAB_DIR}/scripts/homelab-ca.sh  (CA, certificado, exportar raiz)
  Backup ......... diário 03:00 → ${HOMELAB_DIR}/backups  (manual: sudo ${HOMELAB_DIR}/scripts/backup.sh)
  SSD externo .... sudo ${HOMELAB_DIR}/scripts/backup-disk-setup.sh
  IP fixo (LAN) .. sudo ${HOMELAB_DIR}/scripts/network-static.sh
  Internet ....... sudo ${HOMELAB_DIR}/scripts/public-access.sh status|enable|disable
  Log ............ ${LOG_FILE}

${C_YELLOW}  ► Na primeira instalação, reinicie:  sudo reboot${C_RESET}
EOF
