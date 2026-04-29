# Build machine setup — TertoOS

Documentação para configurar o servidor de build do TertoOS extraindo
máximo desempenho. Cobre BIOS, OS, kernel, filesystem, Docker, CPU
governor, RAMdisk, ccache e validação.

**Hardware alvo**: HP ProLiant DL360 Gen9 + 2× Xeon E5-2673 v3/v4 +
128 GB RAM + 2 TB SSD.

**Resultado esperado**: build completa do TertoOS (`make all`) em
**30–60 minutos** após primeira build (com ccache hot), versus
3–4 horas em workstation típica de desenvolvimento.

---

## Sumário

1. [Visão geral](#visão-geral)
2. [Pré-requisitos físicos e BIOS](#pré-requisitos-físicos-e-bios)
3. [Instalação do OS](#instalação-do-os)
4. [Setup automatizado (script)](#setup-automatizado-script)
5. [O que o script faz, em detalhe](#o-que-o-script-faz-em-detalhe)
6. [Validação pós-setup](#validação-pós-setup)
7. [Workflow de build](#workflow-de-build)
8. [Troubleshooting](#troubleshooting)
9. [Rollback](#rollback)

---

## Visão geral

A build do SONiC (e portanto do TertoOS, que é um fork) é dominada por
**três gargalos**:

1. **CPU** — compilação paralela de kernel Linux, FRR (BGP/OSPF/MPLS),
   muitos pacotes Debian, dockers individuais (~30 containers de
   build, cada um com seus próprios `apt install + make`).
2. **Disco** — milhares de operações de escrita/leitura pequenas
   (extract de tarballs, git clone, layers Docker, intermediários de
   compilação).
3. **Rede** — pull de pacotes upstream (Debian mirrors, GitHub).

O DL360 G9 ataca os três:
- 24–40 cores físicos (48–80 threads com HT) → CPU é abundante.
- 128 GB RAM → permite usar **RAMdisk para o working tree**, eliminando
  o gargalo de disco para tudo que é hot.
- 2 TB SSD → guarda artefatos finais e ccache persistente.

A estratégia é:
- Source tree e working dirs em `tmpfs` (RAM).
- ccache em RAM com sync para SSD pós-build (sobrevive reboot).
- Artefatos finais (`.bin`, `.deb`, `.img`) copiados para SSD.
- Configurações de kernel/sysctl/Docker para extrair throughput máximo.

---

## Pré-requisitos físicos e BIOS

Antes de instalar OS, ajuste no **BIOS HP UEFI** ou **iLO**:

### Power Profile

| Setting | Valor recomendado | Por quê |
|---|---|---|
| HP Power Profile | **Maximum Performance** | Desativa todo power saving; CPU sempre em P0. |
| HP Power Regulator | **Static High Performance Mode** | Ignora ACPI hints; força frequência máxima. |
| Minimum Processor Idle Power C-State | **No C-States** | Evita latência de wake-up. CPU nunca dorme. |
| Minimum Processor Idle Power Package C-State | **No Package States** | Mesma ideia, no nível de pacote. |
| Energy/Performance Bias | **Maximum Performance** | Diz ao CPU pra otimizar perf, não consumo. |
| Collaborative Power Control | **Disabled** | Tira controle do OS sobre P-states (vamos forçar via cpupower depois). |

### CPU features

| Setting | Valor |
|---|---|
| Hyper-Threading (HT) | **Enabled** (compilação paralela aproveita threads SMT) |
| Intel Turbo Boost | **Enabled** |
| Intel VT-x | **Enabled** (Docker precisa) |
| Intel VT-d | **Enabled** (para passthrough de NIC se for testar SR-IOV depois) |

### Memory

| Setting | Valor |
|---|---|
| Memory Operating Mode | **Advanced ECC** (default) — protege contra bit flip em build longo |
| Memory Patrol Scrubbing | Enabled |
| Memory Refresh Rate | 1× (default) |

### Storage

- Configure SSD em **AHCI mode** se possível (não RAID — para SSD único, RAID-0 single-disk não traz benefício e adiciona overhead do controller).
- Se passar pelo Smart Array P440ar, configure como **HBA mode (passthrough)** se firmware suportar; senão **RAID-0 single-drive** com cache 100% read.

### iLO

- Deixe iLO acessível na rede de management — útil para reboot remoto durante setup ou se algo travar durante build.
- Set static IP no iLO ou DHCP reservation.

---

## Instalação do OS

### Distro recomendada: **Ubuntu Server 22.04 LTS**

Razões:
- SONiC docs oficiais target 22.04. Mais testado.
- 5 anos de security updates (até 2027 standard, 2032 com Ubuntu Pro).
- Kernel 5.15 default, 6.x via HWE — bom suporte hardware moderno.

Alternativa: Ubuntu 24.04 LTS (mais novo, mas menos testado para SONiC).

### Particionamento

Layout proposto (SSD 2 TB):

```
/boot/efi   1 GB     EFI System Partition
/boot       2 GB     ext4 (kernel images)
/           1900 GB  ext4 (raiz)
swap        16 GB    swap (mais como reserva; com 128GB RAM raramente toca)
```

Não criamos partição separada para `/home` ou `/var` — simplifica e
não há pressão de espaço. O `/mnt/build` virá de tmpfs (RAM), não
ocupa SSD.

### Opções de install

- **Minimal install**: marque "Install OpenSSH server".
- Não instale Docker pelo wizard (vamos instalar a versão oficial).
- Set hostname: `tertoos-build` (ou similar).
- Crie usuário `build` com sudo.

### Pós-install

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

---

## Setup automatizado (script)

Após primeiro reboot pós-install, baixe e rode o script:

```bash
git clone https://github.com/terto-networks/tertoos.git
cd tertoos/build-machine
sudo ./setup.sh
```

O script é **idempotente** (pode rodar várias vezes sem quebrar) e
**não destrutivo** (faz backup de arquivos modificados em
`/var/backups/build-machine/`).

Ele rodará em fases, mostrando progresso. Tempo total: ~10 minutos.

Ao final, ele reinicia o sistema (kernel cmdline mudou). Após reboot,
valide com:

```bash
sudo ./validate.sh
```

Que verifica que tudo subiu certo (governor, tmpfs, sysctl, Docker).

---

## O que o script faz, em detalhe

Cada fase explicada — para entender, customizar, ou debugar.

### Fase 1: Pacotes base

Instala dependências do SONiC build + ferramentas de tuning:

```
build-essential, git, jq, curl, wget, vim, tmux, htop, numactl,
cpufrequtils, irqbalance, ccache, qemu-utils, qemu-system-x86,
debootstrap, sudo, python3, python3-pip
```

Mais Docker (oficial, via apt repo `download.docker.com`).

### Fase 2: Kernel cmdline (GRUB)

Edita `/etc/default/grub` para adicionar:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet mitigations=off transparent_hugepage=always intel_pstate=disable processor.max_cstate=1 idle=poll"
```

**Por quê cada flag**:

| Flag | Efeito | Trade-off |
|---|---|---|
| `mitigations=off` | Desativa Spectre, Meltdown, MDS, etc | **+10–30% perf** em workload heavy CPU. Servidor é dedicado a build, não roda código untrusted da web. Risco aceito. |
| `transparent_hugepage=always` | THP sempre ativo (vs `madvise`) | Reduz TLB misses em workloads memory-heavy (compilação de kernel). |
| `intel_pstate=disable` | Desativa o driver intel_pstate | Permite usar `cpufreq` clássico com governor `performance`, mais previsível. |
| `processor.max_cstate=1` | Não permite C-states profundos (C3+) | CPU sempre quente, sem latência de wake-up. |
| `idle=poll` | CPU faz busy-wait em vez de halt | **Máxima latência mínima**, mas CPU sempre em 100% (mesmo idle). OK para build server dedicado. |

Após edit, roda `update-grub`. Vai ter efeito apenas no próximo
reboot (o script reinicia ao final).

### Fase 3: sysctl tuning

Cria `/etc/sysctl.d/99-tertoos-build.conf`:

```
# VM (memory management)
vm.swappiness = 1                    # Não usa swap quase nunca (temos 128GB RAM)
vm.dirty_ratio = 40                  # 40% RAM pode ser dirty antes de flush forçado
vm.dirty_background_ratio = 5        # Background flush começa em 5%
vm.dirty_expire_centisecs = 12000    # 2 min antes de flush forçado
vm.overcommit_memory = 1             # Permite overcommit (Docker/build precisam)
vm.max_map_count = 1048576           # Map count alto (Docker, JVM)

# fs (filesystem)
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 8192
fs.file-max = 4194304

# net (network buffers para apt/git pull rápido)
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_congestion_control = bbr
```

Aplica imediatamente com `sysctl -p`.

### Fase 4: RAMdisk (tmpfs)

Adiciona ao `/etc/fstab`:

```
# TertoOS build RAMdisks (S14 build-machine setup)
tmpfs   /mnt/build    tmpfs   rw,size=80G,nr_inodes=4M,mode=1777,nosuid,nodev   0  0
tmpfs   /mnt/ccache   tmpfs   rw,size=8G,nr_inodes=1M,mode=1777,nosuid,nodev    0  0
```

Cria os diretórios e monta. **Total 88 GB em RAM**, deixando 40 GB
livres para OS, page cache de SSD, e Docker daemon.

**Por que esses tamanhos**:
- SONiC source tree clone + working dirs: pico observado ~30 GB. 80 GB
  dá folga 2.5×.
- ccache hot (após primeira build): ~3-4 GB. 8 GB dá folga.

**Persistência**: tmpfs evapora em reboot. Solução para ccache:
script de shutdown que copia `/mnt/ccache` para
`/var/cache/ccache-persistent` antes de halt; script de boot que
restaura ao bootar. (Implementado via systemd unit.)

Source tree não persiste — é re-clonável. `git clone` em SSD (~1 min)
+ rsync para tmpfs (~30s) compensa.

### Fase 5: ccache em RAM com persistência

Configura ccache:

```bash
ccache --max-size=6G
ccache --set-config=cache_dir=/mnt/ccache
ccache --set-config=hash_dir=false
ccache --set-config=compression=true
ccache --set-config=compression_level=1   # zstd nivel 1, fast
```

Variáveis em `/etc/profile.d/tertoos-build.sh`:

```bash
export CCACHE_DIR=/mnt/ccache
export CCACHE_MAXSIZE=6G
export PATH="/usr/lib/ccache:$PATH"   # gcc/g++/cc apontam pra ccache
```

systemd units:

- `ccache-restore.service` (oneshot, antes de multi-user.target):
  rsync `/var/cache/ccache-persistent/` → `/mnt/ccache/` se existir.
- `ccache-save.service` (oneshot, em halt/reboot):
  rsync `/mnt/ccache/` → `/var/cache/ccache-persistent/`.

### Fase 6: CPU governor + IRQ affinity

Set `performance` governor em todos os cores:

```bash
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance | sudo tee "$cpu"
done
```

Persiste via systemd: `cpu-performance.service` que reaplica em boot.

IRQs: deixar `irqbalance` rodando (default) — distribui IRQs entre
cores, evita um core saturado servindo todas interrupções de NIC.

### Fase 7: Docker daemon config

Cria `/etc/docker/daemon.json`:

```json
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
```

**Por que cada item**:

| Setting | Razão |
|---|---|
| `overlay2` | Driver storage moderno e rápido (default em Ubuntu 22.04). |
| `data-root /var/lib/docker` | Mantém em SSD, não em RAM (layers persistem; ~10 GB típico). |
| `log-opts` | Limita size de logs Docker — sem isso enchem disco em build longo. |
| `default-ulimits.nofile=1048576` | SONiC build abre muitos arquivos simultaneamente. |
| `max-concurrent-downloads=16` | Pull de imagens base mais rápido no primeiro build. |
| `buildkit=true` | BuildKit é mais rápido que classic builder, parallelism melhor. |

Adiciona usuário `build` ao grupo `docker`:

```bash
usermod -aG docker build
```

(Re-login necessário para tomar efeito; ou `newgrp docker`.)

### Fase 8: Hugepages

Reserva hugepages para Docker/build (opcional, ajuda perf marginal):

```
vm.nr_hugepages = 1024     # 1024 × 2MB = 2 GB de hugepages
```

(Já incluído no sysctl da fase 3.)

### Fase 9: Limites de processos por usuário

`/etc/security/limits.d/99-tertoos-build.conf`:

```
build  soft  nofile  1048576
build  hard  nofile  1048576
build  soft  nproc   65536
build  hard  nproc   65536
build  soft  memlock unlimited
build  hard  memlock unlimited
```

Permite Docker/make/gcc abrirem muitos descritores e processos sem
estourar.

### Fase 10: Tuned network (opcional, se build puxa muito de upstream)

Ajusta MTU se conexão WAN suportar 9000 (jumbo frames):

```bash
ip link set eth0 mtu 9000   # só se infra de rede aceita
```

Default fica 1500. Não scriptado — verificar com sysadmin de rede.

---

## Validação pós-setup

Script `validate.sh` verifica:

1. ✅ `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` retorna `performance`
2. ✅ `cat /proc/cmdline` contém `mitigations=off transparent_hugepage=always`
3. ✅ `mount | grep tmpfs` mostra `/mnt/build` e `/mnt/ccache`
4. ✅ `df -h /mnt/build` retorna ~80G total
5. ✅ `sysctl vm.swappiness` retorna 1
6. ✅ `docker info` retorna ok + storage driver overlay2 + buildkit habilitado
7. ✅ `ulimit -n` retorna 1048576 para o user build
8. ✅ `numactl --hardware` lista 2 nodes com balanceamento ok
9. ✅ `ccache -s` retorna stats vazias (primeira run) com cache_dir=/mnt/ccache
10. ✅ Free RAM ≥ 40 GB (`free -h`)

Se todos passam, máquina está pronta para build.

### Benchmark rápido

```bash
# CPU benchmark — sysbench multi-thread
sudo apt install sysbench
sysbench cpu --threads=$(nproc) --time=30 run | grep "events per second"
```

Esperado em 2× E5-2673 v3: ~25.000 events/s
Esperado em 2× E5-2673 v4: ~40.000 events/s

```bash
# Disco RAMdisk
dd if=/dev/zero of=/mnt/build/test.bin bs=1M count=4096 conv=fdatasync
```

Esperado: ~6-10 GB/s (DDR4-2133 throughput limit). Compare com SSD
(~500 MB/s).

```bash
# Build benchmark — clona e builda libssl
cd /mnt/build
git clone https://github.com/openssl/openssl
cd openssl && time (./config && make -j$(nproc))
```

Esperado: ~1-2 minutos (vs 5-10 min em workstation comum).

---

## Workflow de build

Após validação passar, rode primeira build do TertoOS:

```bash
# Como user build
cd /mnt/build
git clone https://github.com/terto-networks/tertoos.git --recursive
cd tertoos

# Configura jobs paralelos
export SONIC_BUILD_JOBS=$(nproc)

# Pega platform target (ajuste conforme HW alvo)
make configure PLATFORM=broadcom         # para AS5912 Trident III
# ou
make configure PLATFORM=marvell-teralynx # para Centec
# ou
make configure PLATFORM=vs               # para imagem virtual

# Build
make all 2>&1 | tee /var/log/tertoos-build-$(date +%Y%m%d-%H%M).log
```

Saída final em `target/`:
- `target/sonic-broadcom.bin` (NOS image para Trident III)
- `target/sonic-vs.img.gz` (NOS image VM)
- vários `.deb` (pacotes individuais)

**Copia para retenção** em SSD:

```bash
mkdir -p /var/lib/tertoos-builds/$(date +%Y%m%d-%H%M)
cp -r target /var/lib/tertoos-builds/$(date +%Y%m%d-%H%M)/
```

Tmpfs evapora em reboot — sem essa cópia, perde os artefatos.

### Build incremental (após primeira)

Após primeira build (que popula ccache + Docker layers cache):

```bash
# Mudanças pequenas em código TertoOS (ex: KLISH XML, agent Go)
make agent          # apenas agent Go, ~30s
make all SONIC_BUILD_JOBS=$(nproc)   # rebuild incremental, ~5-15 min
```

**ccache hit ratio** após 2-3 builds full deve ser >70% — significa
que de cada 3 arquivos gcc compila, 2 vêm do cache.

```bash
ccache -s   # mostra hit ratio
```

---

## Troubleshooting

### Build trava ou OOM

**Sintoma**: `dmesg | tail` mostra "Out of memory: Kill process".

**Causa**: tmpfs encheu (>80GB) ou Docker daemon usou demais.

**Fix**:
1. Reduzir SONIC_BUILD_JOBS (try `$(($(nproc) / 2))`).
2. Aumentar /mnt/build se tem RAM sobrando (edita /etc/fstab e `mount -o remount,size=100G /mnt/build`).
3. Limpar Docker layers órfãos: `docker system prune -af`.

### CPU governor "voltou" para powersave

**Sintoma**: `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` retorna `powersave` após reboot.

**Causa**: systemd `cpu-performance.service` falhou ou não está enable.

**Fix**:
```bash
sudo systemctl status cpu-performance.service
sudo systemctl enable --now cpu-performance.service
```

### Build muito lento mesmo com tudo configurado

Diagnóstico em ordem:

1. CPU 100% durante build? `htop` durante `make`. Se não, gargalo é outro.
2. tmpfs efetivamente em uso? `df -h /mnt/build` durante build (deve crescer).
3. ccache funcionando? `tail -f /tmp/ccache.log` ou `ccache -s` antes/depois.
4. Network? Primeira build pull ~5-10 GB de upstream. Verificar `iftop`.
5. Docker tem espaço? `df -h /var/lib/docker`. Se cheio, prune.

### Mitigations realmente desabilitadas?

```bash
cat /sys/devices/system/cpu/vulnerabilities/*
```

Cada arquivo deve mostrar "Vulnerable" ou "Mitigation: <something>"
explicitamente como desabilitado. Se mostrar "Mitigation: PTI" sem
"disabled by command line", `mitigations=off` não pegou.

Verificar `/proc/cmdline`: tem que conter literalmente `mitigations=off`.

### Docker não usa BuildKit

`docker info` deve listar "Server Version" e dentro "buildx" plugins.
Se não, BuildKit não habilitou.

```bash
sudo systemctl restart docker
```

E re-confirmar.

---

## Rollback

Se algo der errado e quiser reverter para configuração default Ubuntu:

```bash
sudo ./rollback.sh
```

O script:
1. Restaura `/etc/default/grub` do backup.
2. Remove `/etc/sysctl.d/99-tertoos-build.conf`.
3. Remove entradas tmpfs do `/etc/fstab`.
4. Desativa systemd units customizadas (cpu-performance, ccache-*).
5. Reset CPU governor para `ondemand`.
6. Roda `update-grub`.
7. Pede reboot.

**Não remove**: Docker, ccache (binários/configs), pacotes apt
instalados. Esses ficam — não geram problema.

---

## Performance esperada

Comparativo do mesmo `make all` (TertoOS broadcom target):

| Máquina | Tempo build full | Tempo incremental | Notas |
|---|---|---|---|
| Workstation 8c/16t SSD | 3h 30min | 25 min | Baseline. |
| DL360 G9 24c/48t (E5-2673 v3) sem tuning | 1h 15min | 10 min | Default Ubuntu. |
| DL360 G9 24c/48t **com este setup** | **45–60 min** | **5–8 min** | RAMdisk + ccache + governor + mitigations off. |
| DL360 G9 40c/80t (E5-2673 v4) **com setup** | **30–40 min** | **3–5 min** | Mais cores ajudam até saturar I/O do tmpfs. |

Variação por target — VS é mais rápido (sem syncd-bcm), Centec é mais
lento (Marvell Teralynx tem mais BSP a buildar).

---

## Manutenção contínua

- **Atualização kernel**: `apt full-upgrade` mantém kernel atualizado.
  Após upgrade, GRUB cmdline persiste (escrito em `/etc/default/grub`).
- **Limpeza Docker** mensal: `docker system prune -a` (remove layers
  e imagens não usados).
- **ccache size monitoring**: `ccache -s` mostra hit ratio. Se cair
  abaixo de 50%, considerar aumentar `CCACHE_MAXSIZE`.
- **Logs build**: `/var/log/tertoos-build-*.log` ocupa espaço — rotacionar
  ou deletar mensalmente.
- **iLO firmware**: atualizar a cada 6 meses pra segurança/bugfixes.
