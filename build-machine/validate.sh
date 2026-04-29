#!/usr/bin/env bash
# Valida que setup.sh aplicou tudo corretamente.
# Roda como root ou usuário com sudo.
#
# Saída: lista de checks com ✓ / ✗ / ⚠

set -uo pipefail

PASS=0
FAIL=0
WARN=0

check() {
    local label="$1"
    local cmd="$2"
    local expect="$3"  # regex ou string exata
    local out
    out=$(eval "$cmd" 2>/dev/null || true)
    if [[ "$out" =~ $expect ]]; then
        echo -e "  \033[1;32m✓\033[0m $label"
        PASS=$((PASS+1))
    else
        echo -e "  \033[1;31m✗\033[0m $label"
        echo -e "      esperado: $expect"
        echo -e "      obtido:   $out"
        FAIL=$((FAIL+1))
    fi
}

warn_check() {
    local label="$1"
    local cmd="$2"
    local expect="$3"
    local out
    out=$(eval "$cmd" 2>/dev/null || true)
    if [[ "$out" =~ $expect ]]; then
        echo -e "  \033[1;32m✓\033[0m $label"
        PASS=$((PASS+1))
    else
        echo -e "  \033[1;33m⚠\033[0m $label"
        echo -e "      $out"
        WARN=$((WARN+1))
    fi
}

echo "================================================"
echo " TertoOS build-machine validation"
echo "================================================"

echo
echo "[CPU]"
check "governor=performance" \
    "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor" \
    "performance"
check "kernel cmdline tem mitigations=off" \
    "cat /proc/cmdline" \
    "mitigations=off"
check "kernel cmdline tem THP=always" \
    "cat /proc/cmdline" \
    "transparent_hugepage=always"
warn_check "Spectre/Meltdown desativados" \
    "cat /sys/devices/system/cpu/vulnerabilities/spectre_v2" \
    "Vulnerable|disabled"

echo
echo "[Memory]"
check "RAM total ≥ 64GB" \
    "awk '/MemTotal/ {print int(\$2/1024/1024)}' /proc/meminfo" \
    "(6[4-9]|[7-9][0-9]|[1-9][0-9]{2,})"
check "swappiness=1" \
    "sysctl -n vm.swappiness" \
    "^1$"
check "/mnt/build é tmpfs" \
    "findmnt -n -o FSTYPE /mnt/build" \
    "tmpfs"
check "/mnt/ccache é tmpfs" \
    "findmnt -n -o FSTYPE /mnt/ccache" \
    "tmpfs"
check "/mnt/build size ≥ 60G" \
    "df -BG /mnt/build | tail -1 | awk '{print \$2}'" \
    "^[6-9][0-9]G$|^[1-9][0-9]{2,}G$"

echo
echo "[Network sysctl]"
check "BBR congestion control" \
    "sysctl -n net.ipv4.tcp_congestion_control" \
    "bbr"
check "rmem_max ≥ 128MB" \
    "sysctl -n net.core.rmem_max" \
    "^(13421772[0-9]|[2-9][0-9]{8,})"

echo
echo "[Docker]"
check "Docker rodando" \
    "systemctl is-active docker" \
    "active"
check "storage-driver overlay2" \
    "docker info 2>/dev/null | grep 'Storage Driver'" \
    "overlay2"
warn_check "BuildKit habilitado" \
    "docker info 2>/dev/null | grep -i buildkit" \
    "buildkit|true"

echo
echo "[ccache]"
check "CCACHE_DIR=/mnt/ccache" \
    "grep CCACHE_DIR /etc/profile.d/tertoos-build.sh" \
    "/mnt/ccache"
check "ccache-restore service enabled" \
    "systemctl is-enabled ccache-restore.service" \
    "enabled"
check "ccache-save service enabled" \
    "systemctl is-enabled ccache-save.service" \
    "enabled"

echo
echo "[Services]"
check "cpu-performance.service ativo" \
    "systemctl is-active cpu-performance.service" \
    "active"
check "irqbalance ativo" \
    "systemctl is-active irqbalance" \
    "active"

echo
echo "[Limits]"
warn_check "limits.d configurado" \
    "ls /etc/security/limits.d/99-tertoos-build.conf" \
    "99-tertoos-build"

echo
echo "================================================"
echo " Resultado:"
echo -e "   \033[1;32mPASS:  $PASS\033[0m"
[[ $WARN -gt 0 ]] && echo -e "   \033[1;33mWARN:  $WARN\033[0m"
[[ $FAIL -gt 0 ]] && echo -e "   \033[1;31mFAIL:  $FAIL\033[0m"
echo "================================================"

if [[ $FAIL -gt 0 ]]; then
    echo
    echo "Há checks falhados. Possíveis causas:"
    echo "  1. setup.sh ainda não rodou."
    echo "  2. setup.sh rodou mas reboot pendente — alguns checks"
    echo "     (kernel cmdline) só funcionam após reboot."
    echo "  3. Algum service falhou. Cheque com:"
    echo "       systemctl status cpu-performance ccache-restore"
    exit 1
fi

if [[ $WARN -gt 0 ]]; then
    echo
    echo "Warnings indicam itens não-críticos. Build vai funcionar"
    echo "mas pode estar abaixo do ótimo."
fi

echo
echo "Build machine pronto. Próximo: rodar make all em /mnt/build/tertoos."
