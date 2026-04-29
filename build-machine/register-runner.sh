#!/usr/bin/env bash
# Registra a DL360 como self-hosted runner do GitHub Actions para o
# repo tertoos. Chamar UMA VEZ após primeiro boot da máquina + setup.sh
# concluído.
#
# Pré-requisitos:
# - setup.sh já rodou (Docker, build user existem)
# - Token de runner gerado em GitHub: Settings → Actions → Runners → New
# - Variável de ambiente RUNNER_TOKEN setada (ou prompt interativo)
#
# Uso:
#   sudo ./register-runner.sh
#   sudo RUNNER_TOKEN=ABC123 ./register-runner.sh    # non-interactive
#
# Após registro o runner roda como systemd service e pega jobs
# automaticamente.

set -euo pipefail

# ============================================================
# Defaults
# ============================================================
RUNNER_USER="${RUNNER_USER:-build}"
RUNNER_HOME="/home/$RUNNER_USER/actions-runner"
RUNNER_VERSION="${RUNNER_VERSION:-2.319.1}"
RUNNER_LABELS="self-hosted,tertoos-build,dl360,linux,x64"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)-tertoos}"
REPO_URL="${REPO_URL:-https://github.com/terto-networks/tertoos}"
RUNNER_TOKEN="${RUNNER_TOKEN:-}"

# ============================================================
# Helpers
# ============================================================
log()  { echo -e "\033[1;34m[$(date +%H:%M:%S)]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }

[[ $EUID -eq 0 ]] || err "rode como root (sudo)"

# ============================================================
# Validações
# ============================================================
log "validando ambiente..."
id "$RUNNER_USER" &>/dev/null || err "user '$RUNNER_USER' não existe — rode setup.sh primeiro"
command -v docker &>/dev/null || err "Docker não instalado — rode setup.sh primeiro"
[[ -d /mnt/build ]] || err "/mnt/build não montado — rode setup.sh primeiro"

if [[ -z "$RUNNER_TOKEN" ]]; then
    cat <<EOF

================================================================
 Para gerar token, abra no browser:
   https://github.com/terto-networks/tertoos/settings/actions/runners/new

 Procure pela linha:
   ./config.sh --url ... --token ABC123XYZ
 e copie o valor após --token.
================================================================

EOF
    read -r -p "RUNNER_TOKEN: " RUNNER_TOKEN
    [[ -n "$RUNNER_TOKEN" ]] || err "token vazio"
fi

# ============================================================
# Download + extract runner
# ============================================================
log "baixando runner v$RUNNER_VERSION..."
mkdir -p "$RUNNER_HOME"
cd "$RUNNER_HOME"

if [[ ! -f "config.sh" ]]; then
    curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
    tar xzf runner.tar.gz
    rm runner.tar.gz
    ok "runner extraído em $RUNNER_HOME"
fi

chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_HOME"

# ============================================================
# Instalar dependências do runner
# ============================================================
log "instalando dependências do runner..."
cd "$RUNNER_HOME"
./bin/installdependencies.sh
ok "dependências instaladas"

# ============================================================
# Configure runner (como user 'build')
# ============================================================
log "registrando runner com labels: $RUNNER_LABELS"

# Remove config anterior se existir (idempotência)
sudo -u "$RUNNER_USER" -H bash -c "
    cd '$RUNNER_HOME'
    if [[ -f .runner ]]; then
        echo '[INFO] removendo config anterior...'
        ./config.sh remove --token '$RUNNER_TOKEN' 2>/dev/null || true
    fi
"

sudo -u "$RUNNER_USER" -H bash -c "
    cd '$RUNNER_HOME'
    ./config.sh \
        --url '$REPO_URL' \
        --token '$RUNNER_TOKEN' \
        --name '$RUNNER_NAME' \
        --labels '$RUNNER_LABELS' \
        --work _work \
        --unattended \
        --replace
"
ok "runner registrado"

# ============================================================
# Instalar como systemd service
# ============================================================
log "instalando service systemd..."
cd "$RUNNER_HOME"
./svc.sh install "$RUNNER_USER"
./svc.sh start
sleep 2
./svc.sh status
ok "service rodando"

# ============================================================
# Final
# ============================================================
cat <<EOF

================================================================
 Runner registrado e ativo.
================================================================
 Nome:    $RUNNER_NAME
 Labels:  $RUNNER_LABELS
 Status:  systemctl status actions.runner.terto-networks-tertoos.${RUNNER_NAME}.service
 Logs:    journalctl -u 'actions.runner.terto-networks-tertoos.${RUNNER_NAME}.service' -f

 Verifique no GitHub:
   https://github.com/terto-networks/tertoos/settings/actions/runners

 Próximo passo: dispare workflow manual em GitHub Actions ou faça
 push em master pra ver runner pegando o job.

 Para desregistrar:
   cd $RUNNER_HOME
   sudo ./svc.sh stop
   sudo ./svc.sh uninstall
   sudo -u $RUNNER_USER ./config.sh remove --token <new-token>
================================================================
EOF
