#!/usr/bin/env bash
# Reverte mudanças feitas por setup.sh.
# Restaura GRUB, sysctl, fstab, systemd units. Não desinstala
# Docker/ccache/pacotes apt.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "rode como root (sudo)"; exit 1; }

LATEST_BACKUP=$(ls -1dt /var/backups/build-machine/* 2>/dev/null | head -1 || true)

echo "================================================"
echo " TertoOS build-machine rollback"
echo "================================================"
echo " Backup mais recente: ${LATEST_BACKUP:-NENHUM}"
echo

if [[ -z "$LATEST_BACKUP" ]]; then
    echo "AVISO: sem backup encontrado em /var/backups/build-machine/"
    echo "Vou apenas remover arquivos que setup.sh adicionou."
fi

read -r -p "Continuar com rollback? [y/N]: " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "abortado"; exit 0; }

# 1. Restaurar GRUB
if [[ -f "$LATEST_BACKUP/grub" ]]; then
    cp "$LATEST_BACKUP/grub" /etc/default/grub
    update-grub
    echo "✓ GRUB restaurado do backup"
fi

# 2. Restaurar fstab
if [[ -f "$LATEST_BACKUP/fstab" ]]; then
    cp "$LATEST_BACKUP/fstab" /etc/fstab
    echo "✓ fstab restaurado"
else
    sed -i '/# TertoOS build RAMdisks/,/^$/d' /etc/fstab
    echo "✓ entradas tmpfs removidas do fstab"
fi

# 3. Unmount tmpfs (vai quebrar se estiver em uso)
umount /mnt/build  2>/dev/null || echo "  (skip /mnt/build)"
umount /mnt/ccache 2>/dev/null || echo "  (skip /mnt/ccache)"

# 4. Remover sysctl tunings
rm -f /etc/sysctl.d/99-tertoos-build.conf
echo "✓ sysctl tunings removidos"

# 5. Remover systemd units custom
systemctl disable --now cpu-performance.service 2>/dev/null || true
systemctl disable --now ccache-restore.service 2>/dev/null || true
systemctl disable --now ccache-save.service 2>/dev/null || true
rm -f /etc/systemd/system/cpu-performance.service \
      /etc/systemd/system/ccache-restore.service \
      /etc/systemd/system/ccache-save.service
systemctl daemon-reload
echo "✓ systemd units removidas"

# 6. Reset CPU governor para ondemand
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo ondemand > "$c" 2>/dev/null || true
done
echo "✓ CPU governor resetado"

# 7. Restaurar Docker daemon.json
if [[ -f "$LATEST_BACKUP/daemon.json" ]]; then
    cp "$LATEST_BACKUP/daemon.json" /etc/docker/daemon.json
    systemctl restart docker
    echo "✓ Docker daemon.json restaurado"
else
    rm -f /etc/docker/daemon.json
    systemctl restart docker
    echo "✓ Docker daemon.json removido (volta para defaults)"
fi

# 8. Remover profile + limits
rm -f /etc/profile.d/tertoos-build.sh
rm -f /etc/security/limits.d/99-tertoos-build.conf
echo "✓ profile + limits removidos"

echo
echo "================================================"
echo " Rollback completo. Reboot necessário."
echo "================================================"
read -r -p "Reiniciar AGORA? [y/N]: " ans
[[ "$ans" =~ ^[Yy]$ ]] && reboot
