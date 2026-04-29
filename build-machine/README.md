# build-machine/

Setup do servidor de build do TertoOS. Otimizado para HP DL360 G9 +
2× Xeon E5-2673 v3/v4 + 128 GB RAM + 2 TB SSD, mas funciona em
qualquer servidor com ≥16 cores e ≥64 GB RAM.

## Uso rápido (ordem correta)

```bash
sudo ./setup.sh           # 1. performance (RAMdisk, ccache, governor, Docker)
sudo reboot               #    para ativar kernel cmdline
sudo ./validate.sh        # 2. confere setup OK

# Adicione sua chave SSH ao user 'build' antes de hardening:
# (do laptop) ssh-copy-id build@<DL360-IP>

sudo ./harden.sh          # 3. security (UFW, SSH, fail2ban, sysctl)

# GitHub: gerar token em Settings → Actions → Runners → New
sudo ./register-runner.sh # 4. registra DL360 como GH Actions runner
```

## Arquivos

| Arquivo | Função |
|---|---|
| `BUILD-MACHINE-SETUP.md` | Doc completa nível júnior — performance + cada otimização. |
| `SECURITY.md` | Modelo de segurança em 3 níveis (OS / GitHub / Rede). |
| `CI-PIPELINE.md` | Pipeline GH Actions self-hosted — workflows, security, troubleshoot. |
| `setup.sh` | Performance: RAMdisk, ccache, governor, Docker, etc. |
| `validate.sh` | Health-check pós-setup. |
| `harden.sh` | Security: UFW, SSH harden, fail2ban, unattended-upgrades, sysctl. |
| `register-runner.sh` | Registra DL360 como GH Actions self-hosted runner. |
| `rollback.sh` | Restaura defaults Ubuntu (reverte só `setup.sh`). |

## O que o setup faz

10 fases automatizadas:

1. **Pacotes**: Docker oficial + build-essential + ccache + numactl + ferramentas.
2. **GRUB**: kernel cmdline com `mitigations=off` + `transparent_hugepage=always` + `idle=poll`.
3. **sysctl**: VM tuning, network buffers grandes, BBR, hugepages.
4. **tmpfs**: 80 GB em `/mnt/build` + 8 GB em `/mnt/ccache`.
5. **ccache**: configurado em RAM, persistido em SSD via systemd boot/halt hooks.
6. **CPU governor**: `performance` em todos cores via systemd.
7. **Docker**: daemon.json com BuildKit, ulimits altos, log rotation.
8. **ulimits**: `nofile=1048576`, `nproc=65536` para usuário build.
9. **User**: cria `build` user no grupo docker+sudo.
10. **Housekeeping**: irqbalance, desativa snapd e apt-daily.

## Performance esperada

| Build target | Sem tuning | Com tuning |
|---|---|---|
| `make all PLATFORM=vs` | 60 min | **20–30 min** |
| `make all PLATFORM=broadcom` | 90 min | **40–50 min** |
| Build incremental | 15 min | **3–8 min** (ccache hot) |

## Pré-requisitos

- Ubuntu Server 22.04 LTS (recomendado) ou 24.04 LTS.
- Acesso root (sudo).
- BIOS já ajustado conforme `BUILD-MACHINE-SETUP.md` seção
  "Pré-requisitos físicos e BIOS" — Power Profile Maximum, C-states off,
  HT enabled.

Veja `BUILD-MACHINE-SETUP.md` para detalhes de cada item.
