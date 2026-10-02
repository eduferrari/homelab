#!/usr/bin/env bash
# Registra o runner self-hosted do GitHub Actions e instala como serviço systemd.
# Uso: sudo register-runner.sh <URL_REPO_OU_ORG> <TOKEN> [NOME] [LABELS]
#   TOKEN: GitHub → Settings → Actions → Runners → New self-hosted runner (vale 1 hora)
set -euo pipefail
# shellcheck source=/dev/null
[[ -r "${HOMELAB_CONF:-/etc/homelab.conf}" ]] && . "${HOMELAB_CONF:-/etc/homelab.conf}"
GH_RUNNER_USER="${GH_RUNNER_USER:-gh-runner}"
GH_RUNNER_DIR="${GH_RUNNER_DIR:-/opt/actions-runner}"
[[ $EUID -eq 0 ]] || { echo "Execute com sudo" >&2; exit 1; }
URL="${1:?Informe a URL do repositório/organização}"
TOKEN="${2:?Informe o token de registro}"
NAME="${3:-$(hostname)}"
LABELS="${4:-homelab,linux,x64,docker}"
cd "$GH_RUNNER_DIR"
sudo -u "$GH_RUNNER_USER" ./config.sh --unattended --replace \
  --url "$URL" --token "$TOKEN" --name "$NAME" --labels "$LABELS" --work _work
./svc.sh install "$GH_RUNNER_USER"
./svc.sh start
./svc.sh status
