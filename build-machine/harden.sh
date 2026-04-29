#!/usr/bin/env bash
# harden.sh — security hardening pós-setup.sh.
#
# Aplica defesas OS-side que setup.sh deliberadamente não tocou
# (UFW, SSH config, fail2ban, unattended-upgrades) — em geral pra
# evitar lockout em primeiro setup.
#
# Pré-requisitos:
# - setup.sh rodou (user 'build' existe).
# - User 'build' já tem chave SSH em ~/.ssh/authorized_keys
#   (se não tiver, script avisa e pula desabilitar password auth).
#
# Uso:
#   sudo ./harden.sh                  # interactive
#   sudo ./harden.sh --yes            # non-interactive
#   sudo ./harden.sh --paranoid       # extra restrictions
#
# Idempotente.

set -euo pipefail

# ============================================================
# Config
# ============================================================
ASSUME_YES=0
PARANOID=0
BUILD_USER="build"
SSH_PORT="${SSH_PORT:-22}"

# ============================================================
# Helpers
# ============================================================
log()  { echo -e "\033[1;34m[$(date +%H:%M:%S)]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*"; }

confirm() {
    [[ "$ASSUME_YES" -eq 1 ]] && return 0
    read -r -p "$1 [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

[[ $EUID -eq 0 ]] || err "rode como root (sudo)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) ASSUME_YES=1; shift ;;
        --paranoid) PARANOID=1; shift ;;
        --user=*) BUILD_USER="${1#*=}"; shift ;;
        *) err "unknown arg: $1" ;;
    esac
done

id "$BUILD_USER" &>/dev/null || err "user '$BUILD_USER' não existe — rode setup.sh primeiro"

# ============================================================
# Phase 1: unattended-upgrades (security patches automaticos)
# ============================================================
phase_unattended() {
    log "Phase 1/5: unattended-upgrades..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        unattended-upgrades apt-listchanges

    cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
    // Não auto-update Docker — pode quebrar build em andamento
    "docker-ce";
    "docker-ce-cli";
    "containerd.io";
};
Unattended-Upgrade::DevRelease "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

// IMPORTANTE: NÃO auto-reboot — pode acontecer no meio de uma build.
// Operator decide quando reboot.
Unattended-Upgrade::Automatic-Reboot "false";

// Email opcional (deixa vazio se SMTP não configurado).
// Unattended-Upgrade::Mail "ops@example.com";
EOF

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

    systemctl enable --now unattended-upgrades
    ok "unattended-upgrades configurado (security only, sem auto-reboot)"
}

# ============================================================
# Phase 2: fail2ban (proteção SSH bruteforce)
# ============================================================
phase_fail2ban() {
    log "Phase 2/5: fail2ban..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban

    cat > /etc/fail2ban/jail.d/sshd.conf <<EOF
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 3
findtime = 10m
bantime = 1h
EOF

    systemctl enable --now fail2ban
    fail2ban-client status sshd 2>/dev/null || true
    ok "fail2ban ativo (SSH bruteforce protection)"
}

# ============================================================
# Phase 3: UFW firewall
# ============================================================
phase_ufw() {
    log "Phase 3/5: UFW firewall..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw

    # Reset rules pra estado conhecido (idempotência)
    ufw --force reset >/dev/null

    # Default policies: deny inbound, allow outbound
    ufw default deny incoming
    ufw default allow outgoing

    # SSH allow — única exposição inbound
    ufw allow "$SSH_PORT/tcp" comment 'SSH'

    if [[ $PARANOID -eq 1 ]]; then
        log "  modo paranoid: limitando rate de novas conexões SSH"
        ufw limit "$SSH_PORT/tcp" comment 'SSH rate-limited'
    fi

    # Habilita
    echo "y" | ufw enable >/dev/null
    ufw status verbose
    ok "UFW ativo (apenas SSH inbound, todo outbound permitido)"
}

# ============================================================
# Phase 4: SSH hardening
# ============================================================
phase_ssh() {
    log "Phase 4/5: SSH hardening..."

    # Verifica se user 'build' tem chave autorizada antes de mexer
    local ak="/home/$BUILD_USER/.ssh/authorized_keys"
    local has_key=0
    if [[ -s "$ak" ]]; then
        has_key=1
        log "  user '$BUILD_USER' tem authorized_keys ($(wc -l < "$ak") chave(s))"
    else
        warn "  user '$BUILD_USER' NÃO tem authorized_keys"
        warn "  → Vou aplicar hardening BÁSICO mas DEIXAR password auth ativo"
        warn "  → Adicione sua chave em $ak e rode harden.sh novamente para hardening completo"
    fi

    # Backup sshd_config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak."$(date +%Y%m%d-%H%M%S)"

    local sshd_drop="/etc/ssh/sshd_config.d/99-tertoos-hardening.conf"
    cat > "$sshd_drop" <<EOF
# TertoOS build machine SSH hardening (S14)

# Sempre seguros
PermitRootLogin no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitEmptyPasswords no
PrintMotd no
EOF

    if [[ $has_key -eq 1 ]]; then
        cat >> "$sshd_drop" <<EOF

# user '$BUILD_USER' tem chave — desabilitando password auth
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
EOF
        log "  password auth DESABILITADA (key only)"
    else
        cat >> "$sshd_drop" <<EOF

# user '$BUILD_USER' SEM chave — mantém password auth com defesa em profundidade
# (fail2ban bloqueia bruteforce; UFW limita exposição se --paranoid)
PasswordAuthentication yes
PubkeyAuthentication yes
EOF
    fi

    # Restringe quem pode logar (só user build, evita lockout admin)
    if ! grep -q "^AllowUsers" /etc/ssh/sshd_config; then
        echo "AllowUsers $BUILD_USER" >> "$sshd_drop"
        log "  AllowUsers limitado a '$BUILD_USER'"
    fi

    # Validar config antes de restart (sshd -t)
    if sshd -t; then
        systemctl reload ssh
        ok "SSH hardening aplicado e reload OK"
    else
        warn "sshd config tem erro — não reloadei. Cheque com: sshd -t"
        rm "$sshd_drop"
        err "abortando hardening SSH para evitar lockout"
    fi
}

# ============================================================
# Phase 5: Audit logging + sysctl segurança
# ============================================================
phase_audit_sysctl() {
    log "Phase 5/5: audit logging + kernel sysctl..."

    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq auditd

    # Sysctl security hardening
    cat > /etc/sysctl.d/99-tertoos-security.conf <<'EOF'
# TertoOS security sysctl

# IP forwarding off (não somos router)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
# Mas Docker precisa ip_forward — re-enable se Docker estiver instalado
# (Docker daemon vai setar de volta em start; não é problema)

# Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ICMP redirect ataques
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# SYN flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096

# Source routing off
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Log martian packets (suspicious)
net.ipv4.conf.all.log_martians = 1

# ASLR
kernel.randomize_va_space = 2

# Restringe dmesg para non-root
kernel.dmesg_restrict = 1

# kptr_restrict (esconde ponteiros de kernel)
kernel.kptr_restrict = 2

# Restrict ptrace (impede attaching em outros processos)
kernel.yama.ptrace_scope = 1
EOF

    sysctl -p /etc/sysctl.d/99-tertoos-security.conf >/dev/null

    # Re-enable ip_forward se Docker já está rodando (Docker precisa)
    if systemctl is-active docker &>/dev/null; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
    fi

    ok "audit + sysctl security aplicados"
}

# ============================================================
# Main
# ============================================================
main() {
    log "TertoOS build-machine hardening — iniciando..."
    log "user: $BUILD_USER | SSH port: $SSH_PORT | paranoid: $PARANOID"

    if ! confirm "Aplicar hardening agora?"; then
        warn "abortado"; exit 0
    fi

    phase_unattended
    phase_fail2ban
    phase_ufw
    phase_ssh
    phase_audit_sysctl

    cat <<EOF

================================================
 Hardening COMPLETO
================================================
 ✓ unattended-upgrades  : security patches automáticos (sem reboot)
 ✓ fail2ban             : SSH bruteforce blocking (3 try/10min → ban 1h)
 ✓ UFW                  : inbound deny, outbound allow, SSH allowed
 ✓ SSH config           : PermitRootLogin no, AllowUsers $BUILD_USER, etc.
 ✓ kernel sysctl        : ASLR, rp_filter, syncookies, ptrace restrict

EOF

    if [[ ! -s "/home/$BUILD_USER/.ssh/authorized_keys" ]]; then
        cat <<EOF
 ⚠  PRÓXIMO PASSO IMPORTANTE:
    User '$BUILD_USER' ainda usa password auth.
    Para desabilitar password auth:

      ssh-copy-id -i ~/.ssh/id_ed25519.pub $BUILD_USER@<DL360-IP>
      sudo ./harden.sh --yes

    A 2ª execução vai detectar a chave e desabilitar password auth.

EOF
    fi

    cat <<EOF
 Validação:
   sudo ufw status verbose
   sudo fail2ban-client status sshd
   sudo systemctl status unattended-upgrades
   sshd -t
================================================
EOF
}

main "$@"
