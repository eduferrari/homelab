#!/usr/bin/env bash
# =============================================================================
#  homelab-setup.sh — Provisionamento do homelab (ThinkPad L14 + Ubuntu Server)
#
#  Stack: Docker Engine + Compose | MySQL 8.4 + Adminer | Redis 7 + RedisInsight
#         RabbitMQ 4 + Management | rede "devnet" | SSH | UFW | fail2ban
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
[[ -n "$HOMELAB_USER" ]] || die "Não foi possível detectar o usuário. Use: sudo HOMELAB_USER=<usuario> ./homelab-setup.sh"
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
  unattended-upgrades apt-transport-https bash-completion
ok "Pacotes base instalados"

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

# 24.04+: o ssh.socket define a porta — o generator relê o sshd_config no daemon-reload
if systemctl list-unit-files ssh.socket &>/dev/null && systemctl is-enabled ssh.socket &>/dev/null; then
  systemctl daemon-reload
  systemctl restart ssh.socket
  systemctl restart ssh.service 2>/dev/null || true
else
  systemctl enable ssh >/dev/null 2>&1
  systemctl restart ssh
fi
ok "SSH na porta ${SSH_PORT} | root bloqueado | login por senha: ${PASSWORD_AUTH}"
if [[ "$PASSWORD_AUTH" == "yes" ]]; then
  warn "Login por senha ainda ativo. Copie sua chave (ssh-copy-id) e rode novamente com DISABLE_SSH_PASSWORD=true"
fi

apt_install fail2ban
cat > /etc/fail2ban/jail.d/homelab.local <<EOF
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
ok "UFW ativo: entrada negada por padrão, SSH liberado (com rate-limit)"

# ======================= 7. Estrutura de diretórios ==========================
step "7/11 Criando estrutura de diretórios"
INFRA_DIR="$HOMELAB_DIR/infra"
mkdir -p "$INFRA_DIR"/mysql/{conf.d,init} \
         "$HOMELAB_DIR"/{apps,backups/mysql,scripts} \
         "$USER_HOME"/projects/{apps,libs,sandbox}

chown -R "$HOMELAB_USER":"$HOMELAB_USER" "$USER_HOME/projects"
chown -R "$HOMELAB_USER":docker "$HOMELAB_DIR"
chmod 2775 "$HOMELAB_DIR/apps"   # setgid: arquivos de deploy herdam o grupo docker
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

# ---- Scripts utilitários ----
cat > "$HOMELAB_DIR/scripts/backup-mysql.sh" <<'EOF'
#!/usr/bin/env bash
# Backup de todos os bancos do MySQL (mantém os últimos 7 dias)
set -euo pipefail
DIR="/opt/homelab/backups/mysql"
ENV="/opt/homelab/infra/.env"
KEEP_DAYS="${KEEP_DAYS:-7}"
PASS="$(grep '^MYSQL_ROOT_PASSWORD=' "$ENV" | cut -d= -f2-)"
FILE="$DIR/mysql-$(date +%F_%H%M).sql.gz"
docker exec -e MYSQL_PWD="$PASS" mysql \
  mysqldump -uroot --all-databases --single-transaction --routines --triggers --events \
  | gzip > "$FILE"
find "$DIR" -name 'mysql-*.sql.gz' -mtime +"$KEEP_DAYS" -delete
echo "Backup: $FILE"
EOF

cat > "$HOMELAB_DIR/scripts/status.sh" <<'EOF'
#!/usr/bin/env bash
# Visão rápida do homelab
IP="$(hostname -I | awk '{print $1}')"
echo "== Containers =="; docker compose -f /opt/homelab/infra/docker-compose.yml ps
echo; echo "== Firewall =="; sudo ufw status numbered
echo; echo "== Disco =="; df -h / | tail -1
echo; echo "== Bateria =="; cat /sys/class/power_supply/BAT0/capacity 2>/dev/null | sed 's/$/%/' || echo "n/d"
echo; echo "== UIs =="
echo "Adminer      http://$IP:8080"
echo "RedisInsight http://$IP:5540"
echo "RabbitMQ     http://$IP:15672"
EOF
chmod 750 "$HOMELAB_DIR"/scripts/*.sh
chown "$HOMELAB_USER":docker "$HOMELAB_DIR"/scripts/*.sh

# ======================= 10. Subindo os serviços =============================
step "10/11 Baixando imagens e subindo serviços (pode levar alguns minutos)"
cd "$INFRA_DIR"
docker compose pull -q
docker compose up -d --wait --wait-timeout 240
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
cat <<EOF

${C_GREEN}=====================================================================
  Homelab pronto!  IP: ${IP}
=====================================================================${C_RESET}
  SSH ............ ssh ${HOMELAB_USER}@${IP} -p ${SSH_PORT}
  Adminer ........ http://${IP}:8080       (servidor: mysql)
  RedisInsight ... http://${IP}:5540
  RabbitMQ UI .... http://${IP}:15672
  MySQL .......... ${IP}:3306
  Redis .......... ${IP}:6379
  RabbitMQ AMQP .. ${IP}:5672

  Credenciais .... cat ${ENV_FILE}
  Compose ........ cd ${INFRA_DIR} && docker compose ps
  Status ......... ${HOMELAB_DIR}/scripts/status.sh
  Log ............ ${LOG_FILE}

${C_YELLOW}  ► Reinicie agora para aplicar tudo:  sudo reboot${C_RESET}
    (grupo docker, modo texto, tampa fechada e consoleblank)
EOF
