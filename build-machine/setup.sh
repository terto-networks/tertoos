#!/usr/bin/env bash
# TertoOS build machine setup — DL360 G9 + 2× Xeon E5-2673 + 128GB RAM + 2TB SSD
#
# Aplica todas as otimizações documentadas em BUILD-MACHINE-SETUP.md:
# kernel cmdline, sysctl, tmpfs RAMdisk, ccache, CPU governor, Docker.
#
# Uso (como root):
#   sudo ./setup.sh                      # interactive
#   sudo ./setup.sh --yes                # non-interactive (assume yes)
#   sudo ./setup.sh --user=alice         # set build user (default: build)
#   sudo ./setup.sh --tmpfs-size=120G    # override tmpfs size (default: 80G)
#
# Idempotente: pode rodar várias vezes. Faz backup de arquivos
# modificados em /var/backups/build-machine/<timestamp>/.

set -euo pipefail

# ============================================================
# Config defaults (override via flags)
# ============================================================
ASSUME_YES=0
BUILD_USER="build"
TMPFS_BUILD_SIZE="80G"
TMPFS_CCACHE_SIZE="8G"
CCACHE_MAX_SIZE="6G"
LOG_FILE="/var/log/build-machine-setup.log"

# ============================================================
# Constants
# ============================================================
BACKUP_DIR="/var/backups/build-machine/$(date +%Y%m%d-%H%M%S)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# Helpers
# ============================================================
log()  { echo -e "\033[1;34m[$(date +%H:%M:%S)]\033[0m $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"  | tee -a "$LOG_FILE" >&2; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" | tee -a "$LOG_FILE" >&2; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"    | tee -a "$LOG_FILE"; }

confirm() {
    [[ "$ASSUME_YES" -eq 1 ]] && return 0
    read -r -p "$1 [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

backup_file() {
    local f="$1"
    if [[ -f "$f" ]]; then
        mkdir -p "$BACKUP_DIR"
        cp -a "$f" "$BACKUP_DIR/"
        log "backed up $f → $BACKUP_DIR/"
    fi
}

require_root() {
    [[ $EUID -eq 0 ]] || { err "rode como root (sudo)"; exit 1; }
}

# ============================================================
# Argument parsing
# ============================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) ASSUME_YES=1; shift ;;
            --user=*) BUILD_USER="${1#*=}"; shift ;;
            --tmpfs-size=*) TMPFS_BUILD_SIZE="${1#*=}"; shift ;;
            --help|-h)
                grep -E '^# (Uso|  )' "$0" | sed 's/^# //'
                exit 0
                ;;
            *) err "unknown arg: $1"; exit 2 ;;
        esac
    done
}

# ============================================================
# Sanity checks
# ============================================================
check_hardware() {
    log "validando hardware..."
    local cpu_count mem_gb
    cpu_count=$(nproc)
    mem_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)

    log "  CPUs (threads): $cpu_count"
    log "  RAM: ${mem_gb} GB"

    if [[ $cpu_count -lt 16 ]]; then
        warn "CPU count baixo ($cpu_count threads). Setup é otimizado para ≥24."
    fi
    if [[ $mem_gb -lt 64 ]]; then
        err "RAM insuficiente (${mem_gb} GB). Mínimo recomendado: 64 GB."
        err "tmpfs de ${TMPFS_BUILD_SIZE} não cabe."
        exit 1
    fi
    ok "hardware OK"
}

check_os() {
    log "validando OS..."
    if ! command -v apt-get &>/dev/null; then
        err "este script é específico para Debian/Ubuntu"
        exit 1
    fi
    local ver
    ver=$(lsb_release -rs 2>/dev/null || echo "unknown")
    log "  Ubuntu/Debian version: $ver"
    ok "OS OK"
}

# ============================================================
# Phase 1: pacotes base
# ============================================================
phase_packages() {
    log "Fase 1/10: instalando pacotes base..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        build-essential git jq curl wget vim tmux htop iotop \
        numactl cpufrequtils irqbalance ccache \
        qemu-utils qemu-system-x86 debootstrap \
        rsync sudo python3 python3-pip lsb-release \
        ca-certificates gnupg
    ok "pacotes base instalados"

    log "instalando Docker..."
    if ! command -v docker &>/dev/null; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        local codename
        codename=$(lsb_release -cs)
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $codename stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y -qq \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ok "Docker instalado"
    else
        ok "Docker já presente, skip"
    fi
}

# ============================================================
# Phase 2: kernel cmdline (GRUB)
# ============================================================
phase_grub() {
    log "Fase 2/10: configurando kernel cmdline (GRUB)..."
    local grub="/etc/default/grub"
    backup_file "$grub"

    local cmdline="quiet mitigations=off transparent_hugepage=always intel_pstate=disable processor.max_cstate=1 idle=poll"

    if grep -q "GRUB_CMDLINE_LINUX_DEFAULT" "$grub"; then
        # Replace existing
        sed -i.bak "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$cmdline\"|" "$grub"
    else
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$cmdline\"" >> "$grub"
    fi
    update-grub
    ok "GRUB atualizado (efetivo após reboot)"
}

# ============================================================
# Phase 3: sysctl tuning
# ============================================================
phase_sysctl() {
    log "Fase 3/10: aplicando sysctl tuning..."
    local f="/etc/sysctl.d/99-tertoos-build.conf"
    cat > "$f" <<'EOF'
# TertoOS build machine — sysctl tuning
# Veja BUILD-MACHINE-SETUP.md fase 3 para racional de cada setting.

# VM / memory
vm.swappiness = 1
vm.dirty_ratio = 40
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 12000
vm.overcommit_memory = 1
vm.max_map_count = 1048576
vm.nr_hugepages = 1024

# fs
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
fs.file-max = 4194304

# net (apt/git pull rapido)
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p "$f" >/dev/null
    ok "sysctl aplicado"
}

# ============================================================
# Phase 4: tmpfs RAMdisks
# ============================================================
phase_tmpfs() {
    log "Fase 4/10: configurando RAMdisks (tmpfs)..."
    local fstab="/etc/fstab"
    backup_file "$fstab"

    mkdir -p /mnt/build /mnt/ccache

    # Remove entradas antigas (idempotência)
    sed -i '/# TertoOS build RAMdisks/,/^$/d' "$fstab"

    cat >> "$fstab" <<EOF

# TertoOS build RAMdisks (build-machine setup)
tmpfs   /mnt/build    tmpfs   rw,size=$TMPFS_BUILD_SIZE,nr_inodes=4M,mode=1777,nosuid,nodev   0  0
tmpfs   /mnt/ccache   tmpfs   rw,size=$TMPFS_CCACHE_SIZE,nr_inodes=1M,mode=1777,nosuid,nodev  0  0
EOF

    # Mount agora
    mountpoint -q /mnt/build  && umount /mnt/build  || true
    mountpoint -q /mnt/ccache && umount /mnt/ccache || true
    mount /mnt/build
    mount /mnt/ccache

    ok "RAMdisks montadas: /mnt/build ($TMPFS_BUILD_SIZE), /mnt/ccache ($TMPFS_CCACHE_SIZE)"
}

# ============================================================
# Phase 5: ccache em RAM com persistência via systemd
# ============================================================
phase_ccache() {
    log "Fase 5/10: configurando ccache..."
    local persistent="/var/cache/ccache-persistent"
    mkdir -p "$persistent"
    chmod 1777 "$persistent"
    chown -R "$BUILD_USER:$BUILD_USER" "$persistent" 2>/dev/null || true

    # Profile global (variaveis para todo shell)
    cat > /etc/profile.d/tertoos-build.sh <<EOF
# TertoOS build environment
export CCACHE_DIR=/mnt/ccache
export CCACHE_MAXSIZE=$CCACHE_MAX_SIZE
export PATH="/usr/lib/ccache:\$PATH"
export SONIC_BUILD_JOBS=\$(nproc)
export USE_DOCKER_BUILDKIT=1
export DOCKER_BUILDKIT=1
EOF

    # systemd: restore ccache em boot
    cat > /etc/systemd/system/ccache-restore.service <<EOF
[Unit]
Description=Restore ccache from persistent storage to RAMdisk
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/bin/rsync -a --delete $persistent/ /mnt/ccache/
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

    # systemd: save ccache em halt/reboot
    cat > /etc/systemd/system/ccache-save.service <<EOF
[Unit]
Description=Save ccache from RAMdisk to persistent storage
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target
RequiresMountsFor=/mnt/ccache

[Service]
Type=oneshot
ExecStart=/usr/bin/rsync -a --delete /mnt/ccache/ $persistent/
RemainAfterExit=true

[Install]
WantedBy=halt.target reboot.target shutdown.target
EOF

    systemctl daemon-reload
    systemctl enable ccache-restore.service ccache-save.service

    # Inicializa ccache com config
    sudo -u "$BUILD_USER" -i bash -c "
        export CCACHE_DIR=/mnt/ccache
        ccache --max-size=$CCACHE_MAX_SIZE 2>/dev/null || true
        ccache --set-config=cache_dir=/mnt/ccache 2>/dev/null || true
        ccache --set-config=hash_dir=false 2>/dev/null || true
        ccache --set-config=compression=true 2>/dev/null || true
        ccache --set-config=compression_level=1 2>/dev/null || true
    " 2>/dev/null || warn "user $BUILD_USER ainda não existe — ccache config aplicado apenas globalmente"

    ok "ccache configurado (RAM + persistência via systemd)"
}

# ============================================================
# Phase 6: CPU governor performance
# ============================================================
phase_cpu_governor() {
    log "Fase 6/10: setando CPU governor performance..."

    cat > /etc/systemd/system/cpu-performance.service <<'EOF'
[Unit]
Description=Set all CPUs to performance governor
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$c"; done'
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now cpu-performance.service

    # Aplica imediatamente (caso intel_pstate já esteja desabilitado;
    # se não, falha mudo — vai pegar após reboot quando GRUB ativar).
    for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$c" 2>/dev/null || true
    done

    ok "CPU governor configurado (efetivo após reboot)"
}

# ============================================================
# Phase 7: Docker daemon config
# ============================================================
phase_docker() {
    log "Fase 7/10: configurando Docker daemon..."
    backup_file /etc/docker/daemon.json
    mkdir -p /etc/docker

    cat > /etc/docker/daemon.json <<'EOF'
{
  "storage-driver": "overlay2",
  "data-root": "/var/lib/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 1048576,
      "Soft": 1048576
    },
    "nproc": {
      "Name": "nproc",
      "Hard": 65536,
      "Soft": 65536
    }
  },
  "max-concurrent-downloads": 16,
  "max-concurrent-uploads": 16,
  "experimental": false,
  "features": {
    "buildkit": true
  }
}
EOF

    systemctl restart docker
    ok "Docker reconfigurado"
}

# ============================================================
# Phase 8: limites de processos
# ============================================================
phase_limits() {
    log "Fase 8/10: configurando ulimits..."
    cat > /etc/security/limits.d/99-tertoos-build.conf <<EOF
$BUILD_USER  soft  nofile  1048576
$BUILD_USER  hard  nofile  1048576
$BUILD_USER  soft  nproc   65536
$BUILD_USER  hard  nproc   65536
$BUILD_USER  soft  memlock unlimited
$BUILD_USER  hard  memlock unlimited
EOF
    ok "ulimits configurados para usuário '$BUILD_USER'"
}

# ============================================================
# Phase 9: usuário build
# ============================================================
phase_user() {
    log "Fase 9/10: garantindo usuário '$BUILD_USER' existe..."
    if ! id "$BUILD_USER" &>/dev/null; then
        useradd -m -s /bin/bash "$BUILD_USER"
        ok "usuário $BUILD_USER criado"
    else
        ok "usuário $BUILD_USER já existe"
    fi
    usermod -aG docker "$BUILD_USER"
    usermod -aG sudo  "$BUILD_USER"

    # /mnt/build owned by build user
    chown -R "$BUILD_USER:$BUILD_USER" /mnt/build /mnt/ccache 2>/dev/null || true
    ok "permissões /mnt/build e /mnt/ccache para $BUILD_USER"
}

# ============================================================
# Phase 10: irqbalance + housekeeping
# ============================================================
phase_housekeeping() {
    log "Fase 10/10: housekeeping..."
    systemctl enable --now irqbalance
    systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl disable --now snapd.service snapd.socket 2>/dev/null || true
    ok "serviços ajustados"
}

# ============================================================
# Main
# ============================================================
main() {
    parse_args "$@"
    require_root
    mkdir -p "$(dirname "$LOG_FILE")"
    : > "$LOG_FILE"

    log "TertoOS build-machine setup — iniciando..."
    log "build user: $BUILD_USER"
    log "tmpfs build: $TMPFS_BUILD_SIZE | tmpfs ccache: $TMPFS_CCACHE_SIZE"
    log "log file: $LOG_FILE"
    log "backup dir: $BACKUP_DIR"

    check_hardware
    check_os

    if ! confirm "Continuar com setup completo?"; then
        warn "abortado pelo usuário"; exit 0
    fi

    phase_packages
    phase_grub
    phase_sysctl
    phase_tmpfs
    phase_ccache
    phase_cpu_governor
    phase_docker
    phase_limits
    phase_user
    phase_housekeeping

    ok "================================================"
    ok " Setup COMPLETO"
    ok "================================================"
    ok " Próximos passos:"
    ok "   1. reboot pra ativar kernel cmdline"
    ok "   2. login como '$BUILD_USER'"
    ok "   3. cd /mnt/build && git clone https://github.com/terto-networks/tertoos.git"
    ok "   4. cd tertoos && make configure PLATFORM=<vs|broadcom|...> && make all"
    ok "   5. validar com: sudo $SCRIPT_DIR/validate.sh"
    ok "================================================"

    if confirm "Reiniciar AGORA?"; then
        log "rebooting em 5s..."
        sleep 5
        reboot
    else
        warn "lembre de reiniciar manualmente para ativar kernel cmdline (mitigations=off, etc)"
    fi
}

main "$@"
