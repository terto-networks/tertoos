# CI/CD pipeline — TertoOS

Documentação do pipeline de builds automatizados do TertoOS via
GitHub Actions + servidor self-hosted DL360.

**Modelo**: GitHub Actions é apenas a camada de **orquestração**
(triggers, secrets, status, releases). Todo trabalho de build pesado
executa **localmente** no servidor DL360. Nada compila nos runners
free/paid da GitHub.

## Por que esse modelo

**Vantagens**:
- Custo zero em GH Actions (usa minutos free só para webhook + status).
- Build velocidade total da DL360 (~50min broadcom, ~25min VS).
- ccache + RAMdisk + Docker layers persistem entre runs (ganho enorme
  em builds incrementais).
- Artifacts ficam tanto na GH (web UI) quanto em SSD local da DL360
  (retenção longa).

**Desvantagens**:
- DL360 tem que estar online para qualquer build rodar.
- Single-runner = builds enfileiram (um broadcom + um centec não rodam
  simultâneo no mesmo runner).
- Manutenção: você cuida de updates do runner agent + segurança do
  servidor.

## Glossário

- **GitHub Actions runner**: agente que executa um workflow. Pode ser
  hospedado pelo GitHub (gratuito mas limitado) ou self-hosted
  (servidor seu, registrado no GH).
- **Workflow**: arquivo YAML em `.github/workflows/` que define
  triggers, jobs, e steps.
- **Job**: unidade de trabalho num workflow. Roda em **um** runner.
- **Step**: comando individual dentro de um job.
- **Label**: tag em runner self-hosted; workflow seleciona runner por
  label (`runs-on: [self-hosted, tertoos-build, dl360]`).
- **Concurrency group**: GitHub Actions agrupa jobs pelo nome; só um
  por grupo roda por vez (resto enfileira).

## Visão geral dos workflows

```
.github/workflows/
├── build-vs.yml         ← build VS image (push master, PR, manual)
├── build-broadcom.yml   ← build AS5912 (push master matched paths, tag, manual)
├── build-centec.yml     ← build Centec (idem broadcom)
├── release.yml          ← tag v* dispara 3 builds em paralelo + GH Release
└── lint.yml             ← shellcheck + yamllint (rapido)
```

| Workflow | Trigger | Tempo típico | Output |
|---|---|---|---|
| `build-vs.yml` | push master, PR, manual | 25-30 min | `tertoos-vs-<sha>.qcow2` |
| `build-broadcom.yml` | push master (paths), tag, manual | 50-60 min | `target/sonic-broadcom.bin` |
| `build-centec.yml` | push master (paths), tag, manual | 50-60 min | `target/sonic-marvell-teralynx.bin` |
| `release.yml` | tag `v*.*.*` | 60-90 min (3 paralelos) | GH Release com .qcow2 + .bin + checksums |
| `lint.yml` | push, PR (paths .sh/.yml) | <30s | status check |

## Fluxo de uma build

```
1. Dev faz commit em master OR abre PR
   ↓
2. GitHub Webhook dispara workflow apropriado
   ↓
3. Workflow seleciona runner: runs-on: [self-hosted, tertoos-build, dl360]
   ↓
4. DL360 (runner sempre escutando via systemd) pega o job
   ↓
5. Steps executam SEQUENCIAIS no DL360:
   a. checkout (git clone do workspace)
   b. rsync workspace → /mnt/build/run-<id>/  (RAMdisk)
   c. make configure PLATFORM=...
   d. make all (usa ccache em /mnt/ccache + Docker BuildKit)
   e. cp target/* → /var/lib/tertoos-builds/<id>/  (SSD persistente)
   f. upload-artifact: enviado para GH Actions UI
   g. cleanup: rm -rf /mnt/build/run-<id>
   ↓
6. Status verde/vermelho aparece no PR ou commit
   ↓
7. Em tag push: também cria GitHub Release com artifacts attached
```

## Setup inicial

Pré-requisitos:
- DL360 com `setup.sh` (build-machine) já aplicado e validado.
- Acesso admin ao repo `terto-networks/tertoos` no GitHub.
- Token de runner gerado em GitHub Settings (próximo passo).

### Passo 1: gerar runner token no GitHub

1. Browser: https://github.com/terto-networks/tertoos/settings/actions/runners/new
2. Selecione **Linux** → **x64**.
3. Copie o valor após `--token` na linha `./config.sh ...` mostrada.
   Exemplo: `AAAAA1B2C3D4E5...` (token tem ~30 chars, expira em 1h).

### Passo 2: registrar runner na DL360

```bash
ssh build@<DL360-IP>
cd /path/to/tertoos/build-machine

# Modo interativo (vai perguntar o token)
sudo ./register-runner.sh

# OU non-interactive
sudo RUNNER_TOKEN=AAAAA1B2C3D4E5 ./register-runner.sh
```

O script:
- Baixa o runner agent oficial (v2.319.1 ou mais recente).
- Instala dependências (`./bin/installdependencies.sh`).
- Roda `./config.sh` com labels `self-hosted,tertoos-build,dl360,linux,x64`.
- Instala como systemd service (auto-start em boot).
- Valida que está rodando.

### Passo 3: confirmar registro

No GitHub:
- https://github.com/terto-networks/tertoos/settings/actions/runners
- Deve listar `<hostname>-tertoos` com status verde "Idle".

Na DL360:
```bash
systemctl status 'actions.runner.terto-networks-tertoos.*.service'
journalctl -u 'actions.runner.terto-networks-tertoos.*.service' -f
```

### Passo 4: smoke-test

Dispare um workflow manual:
- GitHub UI → Actions → Build VS → "Run workflow" → master branch
- Acompanhe na UI; deve completar em 20-30 min.
- Cheque artifacts na aba "Summary" do run.

Se passou, pipeline pronto.

## Trigger por target

Cada workflow tem regras de quando dispara:

### `build-vs.yml`
- **Push em master** com mudança em `platform/vs/`, `src/sonic-swss*`, `src/terto-horizon/`, `rules/`, `dockers/`, ou `Makefile*`.
- **Pull request** com mesmas paths (validação de PR antes de merge).
- **Manual** (`workflow_dispatch`) com input opcional `build_jobs`.

VS é a build mais rápida e com mais valor de validação contínua.

### `build-broadcom.yml` / `build-centec.yml`
- **Push em master** com mudança nos paths específicos do platform
  (não dispara em mudanças de doc, agent, etc).
- **Tag push** `v*` (release builds).
- **Manual** dispatch.

Builds pesadas — só rodam quando há mudança real ou release.

### `release.yml`
- **Tag push** `v*.*.*` (semver).
- **Manual** com input do tag name.

Roda 3 builds em paralelo + agrega artifacts + cria GH Release.

## Trigger manual (workflow_dispatch)

Workflow_dispatch permite trigger manual via GitHub UI ou CLI.

**Via UI**:
1. https://github.com/terto-networks/tertoos/actions
2. Selecione workflow.
3. Botão "Run workflow" → escolhe branch + inputs opcionais.

**Via gh CLI**:
```bash
gh workflow run build-vs.yml --ref master
gh workflow run build-broadcom.yml --ref master -f build_jobs=24
gh workflow run release.yml -f tag=v0.1.0
```

## Concurrency e parallelismo

Cada workflow tem `concurrency.group` que controla parallelism:

```yaml
concurrency:
  group: tertoos-build-vs
  cancel-in-progress: false
```

Significa:
- Só **uma** build VS roda por vez (mesmo se 5 PRs abrirem).
- 2ª PR fica enfileirada até a 1ª completar.
- `cancel-in-progress: false` → não cancela a anterior; ela termina
  e a próxima começa.

**Para rodar paralelo no DL360**: cada workflow tem seu próprio
group. broadcom + centec + VS podem rodar simultâneo se DL360 tem
RAM/CPU sobrando (com 128 GB e 24+ cores, dois jobs paralelos em
PLATFORM diferentes funcionam — pode dar sobre alocação de cores e
algum slowdown, mas completam).

Para forçar serialização global (só um job por vez no DL360):
trocar `concurrency.group` para `tertoos-build-global` em todos.

## Security model

⚠️ **Importante**: self-hosted runner em repo público é vetor de
ataque. Qualquer fork pode submeter PR malicioso que executa código
arbitrário na DL360.

### Mitigações em vigor

1. **Repo `tertoos` é privado** (recomendado durante release v0.1).
   Quando virar público, aplicar item 2.

2. **`pull_request_target` NÃO usado** — só `pull_request`. Diferença
   crítica: `pull_request_target` roda no contexto do repo base com
   secrets disponíveis; `pull_request` roda em fork context, sem
   secrets, e (no caso de self-hosted) não dispara em forks por
   default.

3. **Approval required para forks**: GitHub Settings → Actions →
   General → "Require approval for first-time contributors". Com
   isso, PR de fork só roda no runner depois que mantenedor clica
   "approve and run".

4. **Runner roda como user `build`** (não root). Se code malicioso
   conseguir executar, fica limitado a `build` user permissions.
   Docker socket pertence a `build` mas via group docker; mesmo assim,
   user com docker access ≈ root no container. Mitigação adicional:
   considerar runner em VM dedicada ou container.

5. **Network isolation**: DL360 tem acesso à internet (apt, GitHub),
   mas não deve estar exposta a internet (firewall: allow outbound,
   deny inbound exceto SSH com chave). iLO em rede de management
   separada.

6. **Secrets**: NUNCA hardcodar tokens no workflow. Usar
   `${{ secrets.NAME }}` que GitHub injeta apenas em jobs de
   `push`/`workflow_dispatch` em refs do repo (não em PR de fork).

7. **Workflow file permissions**: protected branch master + required
   reviews previne alterações maliciosas em workflows via PR.

### Audit periódico

A cada 3 meses:
- Update runner agent: `cd /home/build/actions-runner && sudo ./svc.sh stop && curl -fsSL https://github.com/actions/runner/releases/download/vX.Y.Z/actions-runner-linux-x64-X.Y.Z.tar.gz | tar xz && sudo ./svc.sh start`.
- Review GitHub Actions logs por padrões anormais.
- Update GH organization secrets (rotate tokens).
- Patch DL360 OS: `sudo apt update && apt full-upgrade && reboot`.

## Cache e otimização

### Docker layer cache

Docker BuildKit reusa layers entre builds. Já configurado no
`daemon.json` da DL360 (`features.buildkit=true`). Primeira build:
pull + build de ~30 dockers. Builds seguintes: maioria reusa layer.

### ccache

Workflows setam `CCACHE_DIR=/mnt/ccache` via env. Persistência via
systemd `ccache-save.service` (configurado no setup.sh).

Verificar hit ratio:
```bash
ssh build@DL360 'ccache -s'
```

Se cache hit < 50%, considerar aumentar `CCACHE_MAXSIZE`:
```bash
ssh build@DL360 'ccache --max-size=10G'
```

### apt cache

SONiC build pulls packages Debian. Apt cache dentro dos containers
Docker é volátil (some quando container é destruído). Mitigação
externa: Squid proxy local no DL360 cacheando apt mirrors.

(Não implementado nesta fatia — defer para v0.2 se for gargalo real.)

## Artifacts e retenção

Workflows produzem artifacts em 2 locais:

### GitHub Actions artifacts (web UI)

Atrelados ao workflow run. Acessível via GitHub Actions → run →
"Summary" → "Artifacts" section. Download via web ou `gh run download`.

Retenção:
- VS builds: 7 dias (rotação rápida, é só smoke).
- Broadcom/Centec builds: 30 dias.
- Release artifacts: permanent (anexados à GH Release).

Tamanho limite: 10GB total por run (free tier). Comprime qcow2 com
`compression-level: 0` (já é compressed) — passa de qcow2 ~1.5GB.

### SSD local da DL360

Workflows também copiam para `/var/lib/tertoos-builds/<run-id>-<target>/`.
Persiste entre reboots. Sem retenção automática — gerenciado manualmente.

Limpeza periódica (sugerida cron):
```bash
find /var/lib/tertoos-builds -mtime +60 -type d -exec rm -rf {} +
```

## Troubleshooting

### Workflow não dispara

Diagnóstico:
1. Workflow é válido? `cd .github/workflows && yamllint *.yml`
2. Trigger paths matcham? Ver linhas `paths:` do workflow vs `git diff`.
3. GitHub Actions habilitado no repo? Settings → Actions → Allow.

### Runner offline

Sintoma: GitHub UI mostra runner com bolinha cinza "offline".

Fix:
```bash
ssh build@DL360
systemctl status 'actions.runner.*'
# Se inativo:
sudo systemctl start 'actions.runner.terto-networks-tertoos.*.service'
journalctl -u 'actions.runner.*' --since '5 minutes ago'
```

Causas comuns:
- DL360 rebootou e service não auto-start (rodar `systemctl enable`).
- Token expirado: re-registrar.
- Disco cheio em `/home/build/actions-runner/_work/`: limpar.

### Build OOM (Out of Memory)

Sintoma: workflow falha com "Killed" no log.

Causas:
- Tmpfs encheu: `df -h /mnt/build` durante run, deve estar < 80%.
- 2 builds paralelos saturaram RAM: serializar via `concurrency.group` global.

Fix:
```bash
# Aumentar tmpfs (precisa unmount/mount):
sudo umount /mnt/build
sudo sed -i 's/size=80G/size=100G/' /etc/fstab
sudo mount /mnt/build
```

### ccache não está sendo usado

Sintoma: builds incrementais não aceleram.

Diagnóstico:
```bash
ssh build@DL360 'ccache -s | grep -E "hit|miss"'
# Hit rate baixo? compilador não está sendo wrapped.
ssh build@DL360 'which gcc'
# Deve retornar /usr/lib/ccache/gcc.
# Se não, PATH errado dentro do container Docker.
```

Workflows setam `CCACHE_DIR` mas Docker containers do SONiC build
podem não herdar PATH `/usr/lib/ccache:$PATH` do host. Workaround:
mount-bind ccache no Docker run command (depende de hooks do SONiC
build system).

### Runner pegou job mas trava

Diagnóstico:
```bash
# Job ID na URL do GitHub run: github.com/.../actions/runs/123456
# No DL360:
ps aux | grep Runner.Worker
# Logs:
tail -f /home/build/actions-runner/_diag/Worker_*.log
```

Se travado em make:
```bash
# Mata o job no GitHub UI. Depois:
ssh build@DL360
docker ps  # Lista containers SONiC build pendurados
docker stop $(docker ps -q)
rm -rf /mnt/build/run-*
```

## Migrar para multi-runner

Se DL360 single-runner virar gargalo, registrar mais runners
(mesma máquina ou outras):

1. Cada runner em `/home/build/actions-runner-N/` com label distinto.
2. Workflows escolhem por label: `runs-on: [self-hosted, tertoos-build]`
   (sem o `dl360` específico permite qualquer runner com `tertoos-build`).
3. GitHub distribui jobs para runners disponíveis.

Não fazer isso até gargalo ser confirmado — single-runner é mais
simples de debugar.

## Phases de deploy

### Phase 1 — Now (commits prontos, runner não registrado)

Workflows estão no repo mas não rodam — falta runner registrado.
Status no GitHub: workflows visíveis mas sem runs.

### Phase 2 — DL360 chega + setup.sh + register-runner.sh

Runner registrado, primeiros workflows disparam. Smoke-test manual:

```bash
gh workflow run build-vs.yml --ref master
gh run watch
```

### Phase 3 — Pós-bring-up validado

Tag `v0.1.0` dispara `release.yml`, build full + GH Release publicado.
Comunidade pode baixar do `https://github.com/terto-networks/tertoos/releases`.
