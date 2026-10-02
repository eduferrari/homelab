#!/usr/bin/env bash
# =============================================================================
#  homelab-setup.sh — Provisionamento do homelab (ThinkPad L14 + Ubuntu Server)
#
#  Stack: Docker Engine + Compose | MySQL 8.4 + Adminer | Redis 7 + RedisInsight
#         RabbitMQ 4 + Management | Caddy (proxy + CA interna) | rede "devnet"
#         Painel: Homepage + Portainer + Uptime Kuma + Cockpit (via Caddy, HTTPS)
#         SSH | UFW | fail2ban | mDNS (.local) | backup diário + restauração
#         tampa fechada sem suspender | preparação GitHub Actions (self-hosted)
#
#  Uso:   sudo ./homelab-setup.sh
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

LOG_FILE="/var/log/homelab-setup.log"

# --------------------------------- Helpers -----------------------------------
C_RESET=$'\e[0m'; C_BLUE=$'\e[1;34m'; C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'
step() { echo -e "\n${C_BLUE}==> $*${C_RESET}"; }
ok()   { echo -e "${C_GREEN}  ✔ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}  ! $*${C_RESET}"; }
die()  { echo -e "${C_RED}  ✘ $*${C_RESET}" >&2; exit 1; }

trap 'die "Falha na linha $LINENO (comando: $BASH_COMMAND). Veja $LOG_FILE"' ERR

gen_secret() { openssl rand -hex 16; }

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

exec > >(tee -a "$LOG_FILE") 2>&1
echo "===== homelab-setup $(date '+%F %T') — usuário: $HOMELAB_USER ====="

# ============================ 1. Sistema base ================================
step "1/11 Atualizando sistema e instalando pacotes base"
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
step "2/11 Preparando Ubuntu para uso como servidor"
if [[ "$HEADLESS" == "true" && "$(systemctl get-default)" == "graphical.target" ]]; then
  systemctl set-default multi-user.target >/dev/null
  ok "Boot alterado para modo texto (multi-user.target) — economiza RAM"
else
  ok "Target de boot: $(systemctl get-default)"
fi

# ======================= 3. Tampa fechada / energia ==========================
step "3/11 Configurando notebook para ficar ligado com a tampa fechada"
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
step "4/11 Configurando SSH"
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

cat > "$SSHD_DROPIN" <<EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication ${PASSWORD_AUTH}
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers ${HOMELAB_USER}
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
ok "SSH na porta ${SSH_PORT} | usuário permitido: ${HOMELAB_USER} | root bloqueado | login por senha: ${PASSWORD_AUTH}"
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
step "5/11 Instalando Docker Engine + Docker Compose (repositório oficial)"
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
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
systemctl enable docker containerd >/dev/null 2>&1
systemctl restart docker
usermod -aG docker "$HOMELAB_USER"
ok "$(docker --version)"
ok "$(docker compose version)"
ok "Usuário $HOMELAB_USER adicionado ao grupo docker"

# ============================== 6. Firewall ==================================
step "6/11 Configurando firewall UFW (+ integração com Docker)"
apt_install ufw
ufw default deny incoming  >/dev/null
ufw default allow outgoing >/dev/null
ufw limit "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
# Caddy roda na rede do HOST (network_mode: host — necessário para HTTPS por IP sem SNI),
# então suas portas passam pelo UFW normalmente: liberadas apenas para redes privadas.
CADDY_RANGE="$(grep -m1 '^CADDY_APP_PORTS=' "$HOMELAB_DIR/infra/.env" 2>/dev/null | cut -d= -f2- || true)"
CADDY_RANGE="${CADDY_RANGE:-8081-8089}"
for net in 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12 100.64.0.0/10; do
  ufw allow proto tcp from "$net" to any port "80,443,${CADDY_RANGE/-/:},9000:9002,9090" comment 'Caddy (LAN)' >/dev/null
  ufw allow proto udp from "$net" to any port 443 comment 'Caddy HTTP/3 (LAN)' >/dev/null
done
# Versões anteriores liberavam o Cockpit (:9091) para as redes Docker; agora ele escuta só em 127.0.0.1
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
ok "UFW ativo: entrada negada por padrão, SSH liberado (com rate-limit), mDNS na LAN"

# ======================= 7. Estrutura de diretórios ==========================
step "7/11 Criando estrutura de diretórios"
INFRA_DIR="$HOMELAB_DIR/infra"
mkdir -p "$INFRA_DIR"/mysql/{conf.d,init} "$INFRA_DIR"/caddy/sites "$INFRA_DIR"/{homepage,portainer} \
         "$HOMELAB_DIR"/{apps,backups/mysql,scripts} \
         "$USER_HOME"/projects/{apps,libs,sandbox}

chown -R "$HOMELAB_USER":"$HOMELAB_USER" "$USER_HOME/projects"
chown "$HOMELAB_USER":docker "$HOMELAB_DIR"
chown -R "$HOMELAB_USER":docker "$HOMELAB_DIR"/{infra,apps,scripts}
chmod 2775 "$HOMELAB_DIR/apps"   # setgid: arquivos de deploy herdam o grupo docker
# Backups contêm segredos (.env, CA do Caddy): só root grava; só o seu usuário lê (para copiar ao Mac)
BACKUP_GROUP="$(id -gn "$HOMELAB_USER")"
chown -R root:"$BACKUP_GROUP" "$HOMELAB_DIR/backups"
chmod 750 "$HOMELAB_DIR/backups"
ok "Infra em $HOMELAB_DIR | projetos em $USER_HOME/projects"

# ============================ 8. Rede Docker =================================
step "8/11 Criando rede Docker '$DOCKER_NETWORK'"
if ! docker network inspect "$DOCKER_NETWORK" &>/dev/null; then
  docker network create --driver bridge "$DOCKER_NETWORK" >/dev/null
  ok "Rede $DOCKER_NETWORK criada"
else
  ok "Rede $DOCKER_NETWORK já existe"
fi

# ======================= 9. Stack de serviços (Compose) ======================
step "9/11 Gerando stack Docker Compose"

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
ADMINER_PORT=8080

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
# Chaves do Caddy: adicionadas em instalações antigas; host/IP atualizados a cada execução
set_env() {
  if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi
}
grep -q '^# Caddy' "$ENV_FILE" || printf '\n# Caddy (proxy reverso + CA interna)\n' >> "$ENV_FILE"
grep -q '^CADDY_APP_PORTS=' "$ENV_FILE" || echo 'CADDY_APP_PORTS=8081-8089' >> "$ENV_FILE"
grep -q '^BACKUP_KEEP_DAYS=' "$ENV_FILE" || printf '\n# Backup (dias de retenção)\nBACKUP_KEEP_DAYS=7\n' >> "$ENV_FILE"
grep -q '^PORTAINER_ADMIN_PASSWORD=' "$ENV_FILE" || \
  printf '\n# Painel de administração\nPORTAINER_ADMIN_PASSWORD=%s\n' "$(gen_secret)" >> "$ENV_FILE"
# Token do monitor "Push" do Uptime Kuma (preenchido por você — veja o README)
grep -q '^UPTIME_KUMA_PUSH_TOKEN=' "$ENV_FILE" || echo 'UPTIME_KUMA_PUSH_TOKEN=' >> "$ENV_FILE"
# Acesso da internet ao Caddy (80/443) — controlado por public-access.sh
grep -q '^PUBLIC_ACCESS=' "$ENV_FILE" || printf '\n# Acesso público (public-access.sh)\nPUBLIC_ACCESS=false\n' >> "$ENV_FILE"
set_env HOMELAB_HOST "$(hostname).local"
set_env HOMELAB_IP "$(hostname -I | awk '{print $1}')"
chown "$HOMELAB_USER":docker "$ENV_FILE"
chmod 640 "$ENV_FILE"

# ---- Caddy: arquivo base (plataforma) + snippets; sites de cada projeto em caddy/sites/*.caddy ----
cat > "$INFRA_DIR/caddy/Caddyfile" <<'EOF'
# Gerado por homelab-setup.sh — NÃO edite (é sobrescrito).
# Sites dos projetos: /opt/homelab/infra/caddy/sites/<projeto>.caddy
{
	# Emissão automática por tipo de nome:
	#   <host>.local e IPs da LAN → CA interna do homelab
	#   domínios públicos (ex.: api.seudominio.com.br) → Let's Encrypt (exige public-access.sh enable)
	skip_install_trust
}

import sites/*.caddy
EOF

cat > "$INFRA_DIR/caddy/sites/00-snippets.caddy" <<'EOF'
# Gerado por homelab-setup.sh — snippets compartilhados pelos sites dos projetos.
# Uso dentro de um site:  import security_headers
#        dentro de reverse_proxy:  import sse

# SSE / streaming: repassa a resposta sem buffer
(sse) {
	flush_interval -1
}

# Restringe o site à rede local (LAN, Docker e Tailscale) — use em tudo que não for público
(lan_only) {
	@fora_da_lan not remote_ip private_ranges 100.64.0.0/10
	abort @fora_da_lan
}

(security_headers) {
	header {
		X-Content-Type-Options nosniff
		Referrer-Policy strict-origin-when-cross-origin
		-Server
	}
}
EOF

cat > "$INFRA_DIR/caddy/sites/_exemplo.caddy.txt" <<'EOF'
# Exemplo de site de projeto — copie para sites/<projeto>.caddy e rode:
#   /opt/homelab/scripts/caddy-reload.sh
#
# {$HOMELAB_HOST} e {$HOMELAB_IP} vêm do .env (o IP é atualizado a cada execução do setup).
# O Caddy roda na rede do HOST (network_mode: host): HTTPS por IP sem SNI só funciona assim.
# Upstreams = porta que o container do projeto publica SÓ em 127.0.0.1, ex.: "127.0.0.1:18080:80".
# Portas atendidas pelo Caddy: 80, 443 e a faixa CADDY_APP_PORTS (padrão 8081-8089).

# Site principal na LAN (443; a porta 80 redireciona para HTTPS)
{$HOMELAB_HOST}, {$HOMELAB_IP} {
	import lan_only
	import security_headers
	reverse_proxy 127.0.0.1:18080
}

# Sistema em porta própria (portas 8081-8089 nunca são expostas à internet)
{$HOMELAB_HOST}:8081, {$HOMELAB_IP}:8081 {
	import lan_only
	import security_headers
	reverse_proxy 127.0.0.1:18081
}

# API com SSE (sem buffer)
{$HOMELAB_HOST}:8083, {$HOMELAB_IP}:8083 {
	import lan_only
	reverse_proxy 127.0.0.1:18083 {
		import sse
	}
}

# Site PÚBLICO (internet) — exige: public-access.sh enable, DNS apontando para o IP
# público e encaminhamento 80/443 no roteador. Certificado Let's Encrypt automático.
# api.seudominio.com.br {
# 	import security_headers
# 	reverse_proxy 127.0.0.1:18083 {
# 		import sse
# 	}
# }
EOF
chown -R "$HOMELAB_USER":docker "$INFRA_DIR/caddy"
chmod 2775 "$INFRA_DIR/caddy/sites"   # deploys (gh-runner, grupo docker) podem gravar sites
ok "Caddy: Caddyfile base + snippets em $INFRA_DIR/caddy"

# ---- Painel de administração -------------------------------------------------
PANEL_HOST="$(hostname).local"
PANEL_IP="$(hostname -I | awk '{print $1}')"

# Sites das ferramentas (plataforma — sobrescrito a cada execução)
cat > "$INFRA_DIR/caddy/sites/10-homelab-admin.caddy" <<'EOF'
# Gerado por homelab-setup.sh — painel de administração do homelab (não editar)

# Porta 80 → HTTPS na 443. Explícito: com vários sites em portas diferentes no mesmo host,
# o redirecionamento automático do Caddy escolhe uma porta qualquer (ex.: 8082).
# Não repita este bloco nos sites dos projetos (o Caddy recusa endereços duplicados).
http://{$HOMELAB_HOST}, http://{$HOMELAB_IP} {
	redir https://{host}{uri} permanent
}

# Homepage (início)
{$HOMELAB_HOST}:9000, {$HOMELAB_IP}:9000 {
	import lan_only
	import security_headers
	reverse_proxy 127.0.0.1:19000
}

# Portainer (containers)
{$HOMELAB_HOST}:9001, {$HOMELAB_IP}:9001 {
	import lan_only
	reverse_proxy 127.0.0.1:19001
}

# Uptime Kuma (monitoramento)
{$HOMELAB_HOST}:9002, {$HOMELAB_IP}:9002 {
	import lan_only
	reverse_proxy 127.0.0.1:3001
}

# Cockpit (host) — escuta só em 127.0.0.1:9091
{$HOMELAB_HOST}:9090, {$HOMELAB_IP}:9090 {
	import lan_only
	reverse_proxy 127.0.0.1:9091
}
EOF

# Cockpit: instalado no host, servido pelo Caddy em https://<host>:9090
apt_install cockpit cockpit-storaged cockpit-packagekit
mkdir -p /etc/cockpit /etc/systemd/system/cockpit.socket.d
cat > /etc/systemd/system/cockpit.socket.d/10-homelab.conf <<'EOF'
[Socket]
ListenStream=
ListenStream=127.0.0.1:9091
EOF
cat > /etc/cockpit/cockpit.conf <<EOF
# Gerado por homelab-setup.sh — Cockpit atrás do Caddy (HTTPS termina no Caddy)
[WebService]
Origins = https://${PANEL_HOST}:9090 https://${PANEL_IP}:9090
ProtocolHeader = X-Forwarded-Proto
AllowUnencrypted = true
LoginTitle = Homelab
EOF
systemctl daemon-reload
systemctl enable cockpit.socket >/dev/null 2>&1
systemctl restart cockpit.socket
ok "Cockpit configurado (127.0.0.1:9091 → Caddy https://${PANEL_HOST}:9090)"

# Portainer: senha do admin aplicada na 1ª inicialização (evita o bloqueio de 5 min do setup web)
grep -m1 '^PORTAINER_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2- | tr -d '\n' > "$INFRA_DIR/portainer/admin_password"
chmod 640 "$INFRA_DIR/portainer/admin_password"

# Homepage: arquivos seus (criados só se não existirem) + arquivos da plataforma (sempre)
HP="$INFRA_DIR/homepage"
[[ -f "$HP/settings.yaml" ]] || cat > "$HP/settings.yaml" <<'EOF'
title: Homelab
language: pt-BR
theme: dark
color: slate
headerStyle: clean
layout:
  Painel:
    style: row
    columns: 4
  Serviços:
    style: row
    columns: 4
  Projetos:
    style: row
    columns: 4
EOF

[[ -f "$HP/services.yaml" ]] || cat > "$HP/services.yaml" <<'EOF'
# Edite à vontade — este arquivo não é sobrescrito pelo setup.
# "container" mostra o status do container (via socket proxy somente leitura).
- Painel:
    - Portainer:
        href: https://{{HOMEPAGE_VAR_HOST}}:9001
        description: "Containers, logs e console"
        icon: portainer.png
        server: homelab
        container: portainer
    - Uptime Kuma:
        href: https://{{HOMEPAGE_VAR_HOST}}:9002
        description: "Monitoramento e alertas"
        icon: uptime-kuma.png
        server: homelab
        container: uptime-kuma
    - Cockpit:
        href: https://{{HOMEPAGE_VAR_HOST}}:9090
        description: "Host, serviços, discos e atualizações"
        icon: cockpit.png
    - Caddy:
        href: https://{{HOMEPAGE_VAR_HOST}}
        description: "Proxy reverso e HTTPS"
        icon: caddy.png
        server: homelab
        container: caddy

- Serviços:
    - Adminer:
        href: http://{{HOMEPAGE_VAR_HOST}}:8080
        description: "MySQL 8.4 (servidor: mysql)"
        icon: adminer.png
        server: homelab
        container: adminer
    - RedisInsight:
        href: http://{{HOMEPAGE_VAR_HOST}}:5540
        description: "Redis 7"
        icon: redis.png
        server: homelab
        container: redisinsight
    - RabbitMQ:
        href: http://{{HOMEPAGE_VAR_HOST}}:15672
        description: "Filas e mensageria"
        icon: rabbitmq.png
        server: homelab
        container: rabbitmq
    - MySQL:
        description: "Banco de dados (porta 3306)"
        icon: mysql.png
        server: homelab
        container: mysql
    - Redis:
        description: "Cache (porta 6379)"
        icon: redis.png
        server: homelab
        container: redis

- Projetos:
    - Site:
        href: https://{{HOMEPAGE_VAR_HOST}}
        description: "Exemplo — ajuste para os seus sistemas"
        icon: mdi-web
EOF

[[ -f "$HP/bookmarks.yaml" ]] || cat > "$HP/bookmarks.yaml" <<'EOF'
- Homelab:
    - Repositório:
        - href: https://github.com/eduferrari/homelab
          icon: github.png
EOF

# Plataforma (sobrescritos): conexão com o Docker e widgets de recursos
cat > "$HP/docker.yaml" <<'EOF'
# Gerado por homelab-setup.sh — acesso somente leitura via docker-socket-proxy
homelab:
  host: dockerproxy
  port: 2375
EOF
{
  echo "# Gerado por homelab-setup.sh"
  echo "- resources:"
  echo "    label: Sistema"
  echo "    cpu: true"
  echo "    memory: true"
  echo "    cputemp: true"
  echo "    uptime: true"
  echo "    disk: /"
  EXT_MNT_HP="$(grep -m1 '^BACKUP_EXTERNAL_MOUNT=' "$ENV_FILE" | cut -d= -f2- || true)"
  if [[ -n "$EXT_MNT_HP" ]]; then
    echo "- resources:"
    echo "    label: SSD de backup"
    echo "    disk: ${EXT_MNT_HP}"
  fi
  echo "- datetime:"
  echo "    text_size: md"
  echo "    locale: pt-BR"
  echo "    format:"
  echo "      dateStyle: long"
  echo "      timeStyle: short"
} > "$HP/widgets.yaml"
chown -R "$HOMELAB_USER":docker "$HP" "$INFRA_DIR/portainer" "$INFRA_DIR/caddy"
ok "Painel: Homepage, Portainer e Uptime Kuma configurados"

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

  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    environment:
      HOMELAB_HOST: ${HOMELAB_HOST}
      HOMELAB_IP: ${HOMELAB_IP}
    # Rede do host: clientes que acessam pelo IP não enviam SNI, e o Caddy escolhe o
    # certificado pelo IP local da conexão — atrás do NAT do Docker ele seria o IP do
    # container e nenhum certificado casaria. Portas: 80, 443, CADDY_APP_PORTS, 9000-9002, 9090
    # (liberadas só para a LAN no UFW). Upstreams: portas publicadas em 127.0.0.1.
    network_mode: host
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy/sites:/etc/caddy/sites:ro
      - caddy_data:/data        # CA interna e certificados — NÃO apague
      - caddy_config:/config

  # ---- Painel de administração ------------------------------------------------
  dockerproxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: dockerproxy
    restart: unless-stopped
    environment:
      CONTAINERS: 1     # somente leitura: lista, status e estatísticas
      POST: 0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [mgmt]

  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    environment:
      TZ: ${TZ}
      HOMEPAGE_ALLOWED_HOSTS: ${HOMELAB_HOST}:9000,${HOMELAB_IP}:9000
      HOMEPAGE_VAR_HOST: ${HOMELAB_HOST}
    ports:
      - "127.0.0.1:19000:3000"  # acessado pelo Caddy (https :9000)
    volumes:
      - ./homepage:/app/config
      - type: bind              # discos para o widget de recursos (SSD montado depois aparece)
        source: /mnt
        target: /mnt
        read_only: true
        bind:
          propagation: rslave
    depends_on: [dockerproxy]
    networks: [devnet, mgmt]

  portainer:
    image: portainer/portainer-ce:lts
    container_name: portainer
    restart: unless-stopped
    command: ["--admin-password-file", "/run/secrets/portainer_admin"]
    ports:
      - "127.0.0.1:19001:9000"  # acessado pelo Caddy (https :9001)
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
      - ./portainer/admin_password:/run/secrets/portainer_admin:ro
    networks: [devnet]

  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    environment:
      TZ: ${TZ}
    ports:
      - "127.0.0.1:3001:3001"   # Caddy (https :9002) e aviso do backup.sh
    volumes:
      - uptime_kuma_data:/app/data
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
  caddy_data:
  caddy_config:
  portainer_data:
  uptime_kuma_data:

networks:
  devnet:
    external: true
  mgmt:
    internal: true    # só homepage ↔ dockerproxy; sem acesso externo
EOF
chown "$HOMELAB_USER":docker "$INFRA_DIR/docker-compose.yml"
ok "docker-compose.yml gerado em $INFRA_DIR"

# ---- Scripts utilitários ----
# backup.sh / restore.sh: cabeçalho com os caminhos desta instalação + corpo fixo
printf '#!/usr/bin/env bash\nHOMELAB_DIR="%s"\nBACKUP_GROUP="%s"\n' "$HOMELAB_DIR" "$BACKUP_GROUP" \
  > "$HOMELAB_DIR/scripts/backup.sh"
cat >> "$HOMELAB_DIR/scripts/backup.sh" <<'EOF'
# Backup do homelab: MySQL, Redis, RabbitMQ (definições), Caddy (CA) e configurações.
# Uso: sudo backup.sh [all|mysql|redis|rabbitmq|caddy|mgmt|config ...]
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
  COMPONENTS=(mysql redis rabbitmq caddy mgmt config)
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

# --------------------------------------------- Aviso para o Uptime Kuma (Push)
# Monitor "Push" no Kuma: sem aviso "up" dentro do intervalo configurado → alerta.
KUMA_TOKEN="$(envget UPTIME_KUMA_PUSH_TOKEN)"
notify_kuma() {
  local code="$1" status=up msg
  (( FULL_RUN )) && [[ -n "$KUMA_TOKEN" ]] || return 0
  case "$code" in
    0) msg="Backup OK" ;;
    2) status=down; msg="Backup local OK, SSD externo indisponível" ;;
    *) status=down; msg="Backup falhou: ${FAILED[*]:-erro antes de iniciar}" ;;
  esac
  msg="$(jq -rn --arg m "$msg" '$m|@uri')"
  curl -fsS -m 10 "http://127.0.0.1:3001/api/push/${KUMA_TOKEN}?status=${status}&msg=${msg}&ping=" >/dev/null \
    || log "  aviso ao Uptime Kuma falhou (container no ar? token correto?)"
}
FAILED=()
trap 'notify_kuma $?' EXIT

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

# ------------------------------------------------------------------- Caddy
backup_caddy() {
  local out="$DEST/caddy-data.tar.gz" vol
  if docker inspect caddy >/dev/null 2>&1; then
    vol="$(volume_of caddy /data)"
    [[ -n "$vol" ]] || { log "  volume /data do caddy não encontrado"; return 1; }
    docker run --rm --entrypoint tar -v "$vol":/data:ro caddy:2-alpine \
      czf - -C /data . > "$out" || return 1
  elif [[ -d /var/lib/caddy/.local/share/caddy ]]; then
    log "  usando Caddy instalado no host (/var/lib/caddy)"
    tar czf "$out" -C /var/lib/caddy/.local/share/caddy . || return 1
  else
    log "  nenhum Caddy encontrado — pulando"
    return 0
  fi
  gzip -t "$out" || return 1
}

# -------------------------------------- Painel (Portainer e Uptime Kuma)
# Bancos embarcados (BoltDB/SQLite): para o container por alguns segundos para
# copiar um estado consistente e sobe de novo.
backup_mgmt() {
  local c path vol out was_running rc=0
  for c in portainer uptime-kuma; do
    case "$c" in portainer) path=/data ;; uptime-kuma) path=/app/data ;; esac
    if ! docker inspect "$c" >/dev/null 2>&1; then log "  $c não existe — pulando"; continue; fi
    vol="$(volume_of "$c" "$path")"
    [[ -n "$vol" ]] || { log "  volume de $c não encontrado"; rc=1; continue; }
    out="$DEST/${c}-data.tar.gz"
    was_running=0; container_up "$c" && was_running=1
    (( was_running )) && { docker stop -t 30 "$c" >/dev/null || { rc=1; continue; }; }
    docker run --rm --entrypoint tar -v "$vol":/data:ro redis:7-alpine czf - -C /data . > "$out" || rc=1
    (( was_running )) && { docker start "$c" >/dev/null || rc=1; }
    gzip -t "$out" || rc=1
  done
  return "$rc"
}

# ----------------------------------------------------------- Configurações
backup_config() {
  local candidates=(
    "$INFRA/docker-compose.yml" "$INFRA/.env" "$INFRA/mysql" "$INFRA/caddy"
    /etc/caddy
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
    /etc/netplan
  )
  local rel=() p
  for p in "${candidates[@]}"; do
    [[ -e "$p" ]] && rel+=("${p#/}")
  done
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
EOF

printf '#!/usr/bin/env bash\nHOMELAB_DIR="%s"\n' "$HOMELAB_DIR" > "$HOMELAB_DIR/scripts/restore.sh"
cat >> "$HOMELAB_DIR/scripts/restore.sh" <<'EOF'
# Restaura um componente a partir de um backup do homelab.
# Uso: sudo restore.sh <pasta-do-backup|latest> <mysql|redis|rabbitmq|caddy|mgmt|config> [--yes]
set -Eeuo pipefail

INFRA="$HOMELAB_DIR/infra"
ENV_FILE="$INFRA/.env"
ROOT="$HOMELAB_DIR/backups"

[[ $EUID -eq 0 ]] || { echo "Execute com sudo: sudo $0 $*" >&2; exit 1; }

usage() {
  echo "Uso: sudo $0 <pasta-do-backup|latest> <mysql|redis|rabbitmq|caddy|mgmt|config> [--yes]"
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

  caddy)
    need caddy-data.tar.gz
    if ! docker inspect caddy >/dev/null 2>&1; then
      echo "Container caddy não existe. Para Caddy instalado no host:"
      echo "  sudo systemctl stop caddy"
      echo "  sudo tar xzf $SRC/caddy-data.tar.gz -C /var/lib/caddy/.local/share/caddy"
      echo "  sudo chown -R caddy:caddy /var/lib/caddy && sudo systemctl start caddy"
      exit 1
    fi
    confirm "Isto SUBSTITUI a CA interna e os certificados do Caddy pelos de $(basename "$SRC")."
    VOL="$(volume_of caddy /data)"
    dc stop caddy >/dev/null
    docker run --rm -i -v "$VOL":/data --entrypoint sh caddy:2-alpine -c \
      'find /data -mindepth 1 -delete && tar xzf - -C /data' < "$SRC/caddy-data.tar.gz"
    dc start caddy >/dev/null
    log "Caddy restaurado. Confira a impressão digital: $HOMELAB_DIR/scripts/caddy-ca.sh"
    ;;

  mgmt)
    confirm "Isto SUBSTITUI os dados do Portainer e do Uptime Kuma pelos de $(basename "$SRC")."
    for c in portainer uptime-kuma; do
      [[ -f "$SRC/${c}-data.tar.gz" ]] || { log "$c: sem arquivo no backup — pulando"; continue; }
      case "$c" in portainer) path=/data ;; uptime-kuma) path=/app/data ;; esac
      VOL="$(volume_of "$c" "$path")"
      [[ -n "$VOL" ]] || { log "$c: container/volume não encontrado — rode o setup antes"; continue; }
      dc stop "$c" >/dev/null
      docker run --rm -i -v "$VOL":/data --entrypoint sh redis:7-alpine -c \
        'find /data -mindepth 1 -delete && tar xzf - -C /data' < "$SRC/${c}-data.tar.gz"
      dc start "$c" >/dev/null
      log "$c restaurado."
    done
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
EOF

# Preparação do SSD externo (comando separado — veja o README)
printf '#!/usr/bin/env bash\nHOMELAB_DIR="%s"\nBACKUP_GROUP="%s"\n' "$HOMELAB_DIR" "$BACKUP_GROUP" \
  > "$HOMELAB_DIR/scripts/backup-disk-setup.sh"
cat >> "$HOMELAB_DIR/scripts/backup-disk-setup.sh" <<'EOF'
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
EOF

# IP fixo na LAN (comando separado)
cat > "$HOMELAB_DIR/scripts/network-static.sh" <<'EOF'
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
  echo "  Depois rode o setup para atualizar Caddy, Homepage e Cockpit com o IP:"
  echo "    cd ~/homelab && sudo ./homelab-setup.sh"
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
EOF

# Acesso da internet ao Caddy (comando separado)
printf '#!/usr/bin/env bash\nHOMELAB_DIR="%s"\n' "$HOMELAB_DIR" > "$HOMELAB_DIR/scripts/public-access.sh"
cat >> "$HOMELAB_DIR/scripts/public-access.sh" <<'EOF'
# Libera o acesso da INTERNET ao Caddy (80/443) para sites com domínio público.
# Todo o resto (painel 9000-9002/9090, portas 8081-8089, bancos, SSH) continua só na LAN.
#
#   sudo public-access.sh status
#   sudo public-access.sh enable
#   sudo public-access.sh disable
set -Eeuo pipefail

ENV_FILE="$HOMELAB_DIR/infra/.env"
die() { echo "✘ $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Execute com sudo: sudo $0 $*"

set_env() {
  if grep -q "^$1=" "$ENV_FILE"; then sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"; else echo "$1=$2" >> "$ENV_FILE"; fi
}

# O Caddy roda na rede do host: as portas 80/443 são liberadas no UFW como qualquer serviço do host
RULES=("80/tcp" "443/tcp" "443/udp")

public_ip() { curl -fsS -m 5 https://api.ipify.org 2>/dev/null || echo "?"; }
lan_ip()    { hostname -I | awk '{print $1}'; }

show_status() {
  local state; state="$(grep -m1 '^PUBLIC_ACCESS=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  echo "Acesso público ..... ${state:-false}"
  echo "IP público ......... $(public_ip)"
  echo "IP na LAN .......... $(lan_ip)"
  echo "Regras públicas (UFW):"
  ufw status | grep -E 'Caddy publico' | sed 's/^/  /' || echo "  (nenhuma)"
}

case "${1:-status}" in
  enable)
    for r in "${RULES[@]}"; do
      # shellcheck disable=SC2086
      ufw allow $r comment 'Caddy publico' >/dev/null
    done
    set_env PUBLIC_ACCESS true
    ufw reload >/dev/null
    echo "✔ Internet → Caddy liberado (80/tcp, 443/tcp, 443/udp)."
    echo
    show_status
    echo
    echo "Próximos passos:"
    echo "  1. No roteador/ONT: encaminhe as portas 80/tcp, 443/tcp e 443/udp para $(lan_ip)"
    echo "     (o L14 precisa de IP fixo na LAN — network-static.sh)."
    echo "  2. No DNS do seu domínio: registro A  ex.: api.seudominio.com.br → $(public_ip)"
    echo "  3. Crie o site público em /opt/homelab/infra/caddy/sites/<projeto>.caddy:"
    echo "       api.seudominio.com.br {"
    echo "           reverse_proxy 127.0.0.1:18083"
    echo "       }"
    echo "     e rode /opt/homelab/scripts/caddy-reload.sh — o certificado Let's Encrypt é automático."
    echo "  4. Teste de FORA da sua rede (ex.: 4G do celular): https://api.seudominio.com.br"
    ;;
  disable)
    for r in "${RULES[@]}"; do
      # shellcheck disable=SC2086
      ufw delete allow $r >/dev/null 2>&1 || true
    done
    set_env PUBLIC_ACCESS false
    ufw reload >/dev/null
    echo "✔ Acesso da internet bloqueado. Lembre de remover o encaminhamento no roteador."
    ;;
  status) show_status ;;
  *) die "Uso: sudo $0 [status|enable|disable]" ;;
esac
EOF

# Compatibilidade com a versão anterior
cat > "$HOMELAB_DIR/scripts/backup-mysql.sh" <<'EOF'
#!/usr/bin/env bash
# Mantido por compatibilidade — use backup.sh
exec "$(dirname "$0")/backup.sh" mysql
EOF

cat > "$HOMELAB_DIR/scripts/status.sh" <<'EOF'
#!/usr/bin/env bash
# Visão rápida do homelab
IP="$(hostname -I | awk '{print $1}')"
HOST="$(hostname).local"
echo "== Rede =="; echo "IP: $IP | mDNS: $HOST"; echo
echo "== Containers =="; docker compose -f /opt/homelab/infra/docker-compose.yml ps
echo; echo "== Firewall =="; sudo ufw status numbered
echo; echo "== Disco =="; df -h / | tail -1
echo; echo "== Bateria =="; cat /sys/class/power_supply/BAT0/capacity 2>/dev/null | sed 's/$/%/' || echo "n/d"
echo; echo "== UIs =="
echo "Adminer      http://$HOST:8080"
echo "RedisInsight http://$HOST:5540"
echo "RabbitMQ     http://$HOST:15672"
echo "Caddy        https://$HOST  (sites em /opt/homelab/infra/caddy/sites)"
echo; echo "== Painel =="
echo "Homepage     https://$HOST:9000"
echo "Portainer    https://$HOST:9001"
echo "Uptime Kuma  https://$HOST:9002"
echo "Cockpit      https://$HOST:9090"
echo; echo "== Backup =="
LAST="$(readlink /opt/homelab/backups/latest 2>/dev/null || echo 'nenhum')"
echo "Último backup completo: $LAST"
systemctl list-timers homelab-backup.timer --no-pager 2>/dev/null | sed -n 2p
EXT_MNT="$(grep -m1 '^BACKUP_EXTERNAL_MOUNT=' /opt/homelab/infra/.env 2>/dev/null | cut -d= -f2-)"
EXT_DIR="$(grep -m1 '^BACKUP_EXTERNAL_DIR=' /opt/homelab/infra/.env 2>/dev/null | cut -d= -f2-)"
if [[ -z "$EXT_MNT" ]]; then
  echo "SSD externo: não configurado (sudo /opt/homelab/scripts/backup-disk-setup.sh)"
elif mountpoint -q "$EXT_MNT"; then
  echo "SSD externo: montado em $EXT_MNT | livre $(df -h --output=avail "$EXT_MNT" | tail -1 | tr -d ' ') | último: $(readlink "$EXT_DIR/latest" 2>/dev/null || echo 'nenhum')"
else
  echo "SSD externo: ⚠️  NÃO montado em $EXT_MNT — conecte o disco"
fi
EOF
cat > "$HOMELAB_DIR/scripts/caddy-reload.sh" <<'EOF'
#!/usr/bin/env bash
# Valida e recarrega o Caddy sem derrubar conexões (use após alterar caddy/sites/*.caddy)
set -euo pipefail
docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec caddy caddy reload   --config /etc/caddy/Caddyfile --adapter caddyfile
echo "Caddy recarregado."
EOF

cat > "$HOMELAB_DIR/scripts/caddy-ca.sh" <<'EOF'
#!/usr/bin/env bash
# Exporta o certificado raiz da CA interna do Caddy e mostra a impressão digital (SHA-256)
set -euo pipefail
OUT="${1:-/opt/homelab/infra/caddy/homelab-root-ca.crt}"
docker exec caddy cat /data/caddy/pki/authorities/local/root.crt > "$OUT"
echo "CA exportada: $OUT"
openssl x509 -in "$OUT" -noout -subject -enddate -fingerprint -sha256
EOF

chmod 750 "$HOMELAB_DIR"/scripts/*.sh
chown "$HOMELAB_USER":docker "$HOMELAB_DIR"/scripts/*.sh

# Backup diário às 03:00 (systemd: roda como root, log no journal, recupera execuções perdidas)
cat > /etc/systemd/system/homelab-backup.service <<EOF
[Unit]
Description=Backup do homelab (MySQL, Redis, RabbitMQ, Caddy, configurações) + cópia para SSD externo
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
systemctl daemon-reload
systemctl enable --now homelab-backup.timer >/dev/null 2>&1
ok "Backup diário agendado (homelab-backup.timer, 03:00) — retenção: BACKUP_KEEP_DAYS no .env"

# ======================= 10. Subindo os serviços =============================
step "10/11 Baixando imagens e subindo serviços (pode levar alguns minutos)"
cd "$INFRA_DIR"
docker compose pull -q

# Não sobe o Caddy da stack se já houver outro Caddy/servidor ocupando a 443
UP_ARGS=(-d --wait --wait-timeout 240)
CADDY_CONFLICT=""
if systemctl is-active --quiet caddy 2>/dev/null; then
  CADDY_CONFLICT="Caddy instalado no host (apt) está ativo"
elif ss -tlnH 'sport = :443' | grep -q . && \
     [[ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' caddy 2>/dev/null)" != "homelab" ]]; then
  CADDY_CONFLICT="a porta 443 já está em uso por outro processo/container"
fi
if [[ -n "$CADDY_CONFLICT" ]]; then
  warn "Container caddy da stack NÃO iniciado: ${CADDY_CONFLICT}. Veja 'Migrar um Caddy existente' no README."
  warn "Sem o Caddy da stack, o painel (portas 9000-9002 e 9090) fica inacessível."
  UP_ARGS+=(--scale caddy=0)
fi
docker compose up "${UP_ARGS[@]}"
if [[ -z "$CADDY_CONFLICT" ]] && docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  ok "Caddy recarregado com a configuração atual"
fi
ok "Serviços no ar"
docker compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'

# =================== 11. Preparação GitHub Actions ===========================
step "11/11 Preparando GitHub Actions self-hosted runner"
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

  cat > "$HOMELAB_DIR/scripts/register-runner.sh" <<EOF
#!/usr/bin/env bash
# Registra o runner no GitHub e instala como serviço systemd.
# Uso: sudo $HOMELAB_DIR/scripts/register-runner.sh <URL_REPO_OU_ORG> <TOKEN> [NOME] [LABELS]
set -euo pipefail
URL="\${1:?Informe a URL do repositório/organização}"
TOKEN="\${2:?Informe o token de registro (Settings > Actions > Runners > New)}"
NAME="\${3:-\$(hostname)}"
LABELS="\${4:-homelab,linux,x64,docker}"
cd "$GH_RUNNER_DIR"
sudo -u "$GH_RUNNER_USER" ./config.sh --unattended --replace \\
  --url "\$URL" --token "\$TOKEN" --name "\$NAME" --labels "\$LABELS" --work _work
./svc.sh install "$GH_RUNNER_USER"
./svc.sh start
./svc.sh status
EOF
  chmod 750 "$HOMELAB_DIR/scripts/register-runner.sh"
  ok "Para registrar: sudo $HOMELAB_DIR/scripts/register-runner.sh <url> <token>"
else
  warn "Preparação do runner ignorada (PREPARE_GH_RUNNER=false)"
fi

# ================================ Resumo =====================================
IP="$(hostname -I | awk '{print $1}')"
HOST="$(hostname).local"
cat <<EOF

${C_GREEN}=====================================================================
  Homelab pronto!  ${HOST}  (IP atual: ${IP})
=====================================================================${C_RESET}
  SSH ............ ssh ${HOMELAB_USER}@${HOST} -p ${SSH_PORT}
  Adminer ........ http://${HOST}:8080       (servidor: mysql)
  RedisInsight ... http://${HOST}:5540
  RabbitMQ UI .... http://${HOST}:15672
  MySQL .......... ${HOST}:3306
  Redis .......... ${HOST}:6379
  RabbitMQ AMQP .. ${HOST}:5672
  Caddy (HTTPS) .. https://${HOST}  — sites em ${INFRA_DIR}/caddy/sites

  Painel ......... https://${HOST}:9000  (Homepage)
  Portainer ...... https://${HOST}:9001  (usuário admin — senha: PORTAINER_ADMIN_PASSWORD no .env)
  Uptime Kuma .... https://${HOST}:9002  (crie o admin no 1º acesso)
  Cockpit ........ https://${HOST}:9090  (login: ${HOMELAB_USER})
  CA do Caddy .... ${HOMELAB_DIR}/scripts/caddy-ca.sh  (instale nos dispositivos)
  Backup ......... diário 03:00 → ${HOMELAB_DIR}/backups  (manual: sudo ${HOMELAB_DIR}/scripts/backup.sh)
  SSD externo .... sudo ${HOMELAB_DIR}/scripts/backup-disk-setup.sh  (lista discos e prepara a cópia)
  IP fixo (LAN) .. sudo ${HOMELAB_DIR}/scripts/network-static.sh     (mostra a rede e fixa o IP)
  Internet ....... sudo ${HOMELAB_DIR}/scripts/public-access.sh status|enable|disable

  Use o nome ${HOST}: o IP pode mudar a cada reboot (DHCP).

  Credenciais .... cat ${ENV_FILE}
  Compose ........ cd ${INFRA_DIR} && docker compose ps
  Status ......... ${HOMELAB_DIR}/scripts/status.sh
  Log ............ ${LOG_FILE}

${C_YELLOW}  ► Reinicie agora para aplicar tudo:  sudo reboot${C_RESET}
    (grupo docker, modo texto, tampa fechada e consoleblank)
EOF
