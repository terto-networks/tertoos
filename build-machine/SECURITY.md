# Security checklist — TertoOS build machine + GitHub Actions

Modelo de segurança em **3 níveis independentes**: OS (DL360), GitHub
(repo + workflows), Rede (LAN onde o servidor vive). Cada um endereça
um vetor de ataque distinto.

Este doc explica o que **já foi aplicado pelos scripts**, o que precisa
**configuração manual**, e o que é **manutenção contínua**.

---

## Modelo de ameaças (threat model)

Antes de cada item ficar concreto, qual ataque ele defende contra:

| Ameaça | Origem | Impacto |
|---|---|---|
| **Workflow malicioso via PR de fork** | Comunidade GitHub | Code execution na DL360 → exfiltração, miner, persistência |
| **Bruteforce SSH da internet** | Bots na internet | Credencial fraca → shell access |
| **LAN insider/host comprometido** | Atacante já na rede | SSH/exposed services → shell access |
| **Supply chain (apt/Docker)** | Mirror comprometido | Build artifacts contaminados |
| **CVE em kernel/serviços** | Vulnerabilidade pública | Privilege escalation, RCE |
| **Token GH leaked** | Commit acidental, log file | Push em master, modificar workflows |

---

## Nível 1 — OS (DL360)

### Já aplicado por `setup.sh` ✅

Quando você rodar `sudo ./setup.sh` (build-machine setup), os seguintes
itens de segurança já entram pelo caminho:

- ✅ User `build` não-root (UID padrão >1000).
- ✅ `umask` padrão (022) — arquivos não world-writable.
- ✅ `nofile` ulimit alto (não é segurança, é estabilidade — mas previne
  DoS por exhaustion).
- ✅ Snapd desabilitado (reduz attack surface — você não usa snaps).
- ✅ apt-daily desativado (vamos rodar manualmente, evita race com build).

### NÃO aplicado por `setup.sh` (deliberado)

`setup.sh` é foco em **performance**, não em hardening. Ele NÃO:

- ❌ Configura firewall (UFW).
- ❌ Hardenia SSH (deixa default Ubuntu).
- ❌ Instala fail2ban.
- ❌ Configura unattended-upgrades.
- ❌ Aplica sysctl de segurança (ASLR, rp_filter, etc).

**Razão**: rodar hardening cego antes de chave SSH estar configurada
pode causar lockout. `setup.sh` deixa decidir quando aplicar.

### Aplicar com `harden.sh` ✅ (depois do setup)

```bash
# Pré-requisito: você consegue logar na DL360 via SSH com sucesso
# (ainda com password OK, pois harden detecta se há chave configurada).

# 1. (recomendado) Adicionar sua chave SSH ao user build PRIMEIRO:
ssh-copy-id -i ~/.ssh/id_ed25519.pub build@<DL360-IP>

# 2. Logar na DL360 e rodar harden.sh
ssh build@<DL360-IP>
cd /path/to/tertoos/build-machine
sudo ./harden.sh           # interactive
sudo ./harden.sh --yes     # batch
sudo ./harden.sh --paranoid  # extra: rate-limit SSH no UFW
```

`harden.sh` aplica:
- ✅ `unattended-upgrades` para security patches automáticos
  (Docker excluído da lista — evita break mid-build).
  **Auto-reboot DESABILITADO** — operator decide quando.
- ✅ `fail2ban` com jail SSH (3 try/10min → ban 1h).
- ✅ UFW: inbound `deny` exceto SSH; outbound `allow`.
- ✅ SSH config drop-in `/etc/ssh/sshd_config.d/99-tertoos-hardening.conf`:
  - `PermitRootLogin no`
  - `MaxAuthTries 3`, `LoginGraceTime 30`
  - `AllowUsers build` (limita quem pode logar)
  - `PasswordAuthentication no` **se user build tem `authorized_keys`**
    (auto-detecta para evitar lockout)
- ✅ Sysctl security: ASLR full, rp_filter, syncookies, source-route
  off, dmesg restrict, kptr_restrict, ptrace_scope=1.
- ✅ `auditd` instalado (logs de eventos de sistema).

### O que ainda fica como manutenção contínua ⚠️

Mesmo após `harden.sh`, há rotinas mensais/trimestrais:

| Rotina | Frequência | Comando |
|---|---|---|
| **Patches kernel/Docker** (não cobertos por unattended) | Mensal | `sudo apt full-upgrade && sudo reboot` (em janela de manutenção) |
| **Update GH Actions runner agent** | Trimestral | Ver seção "Manutenção runner" abaixo |
| **Rotate SSH keys do user build** | Anual ou em offboarding | Re-gerar key do laptop dev, `ssh-copy-id`, remover key antiga |
| **Audit `journalctl -p warning` + `fail2ban-client status sshd`** | Mensal | Ver se há padrão de attack |
| **Review `last` + `lastb`** | Mensal | Logins suspeitos? |

---

## Nível 2 — GitHub repo + Actions

Isto é **manual** — não há script que configure GitHub via API
(seria possível mas adiciona complexidade pra benefício marginal).
Faz uma vez quando o repo for criado.

### Settings obrigatórios

#### 2.1. Repo privacy

Para a **release v0.1**, manter repo `tertoos` **PRIVADO**.

```
Settings → General → Danger Zone → Change visibility → Private
```

Razão: self-hosted runner em repo público é vetor de ataque mesmo
com mitigações abaixo. Privado elimina o vetor de fork PR malicioso
(externos não veem nem submetem PR).

Quando virar público (post-v1.0), aplicar items 2.2-2.4 com cuidado
extra.

#### 2.2. Branch protection no `master`

```
Settings → Branches → Add branch protection rule
  Branch name pattern: master
  ☑ Require a pull request before merging
    ☑ Require approvals: 1 (ou mais se time ≥2)
  ☑ Require status checks to pass before merging
    ☑ Require branches to be up to date
    ☑ Require these checks: build-vs, lint
  ☑ Require conversation resolution
  ☑ Do not allow bypassing the above settings
```

Garante que mudanças em workflow files passam por review (auto-PR não
consegue alterar `.github/workflows/`).

#### 2.3. Actions permissions

```
Settings → Actions → General

Actions permissions:
  ◉ Allow <org>, and select non-<org>, actions and reusable workflows
    ☑ Allow actions created by GitHub
    ☑ Allow Marketplace actions by verified creators
    Allow specified actions:
      softprops/action-gh-release@*
      actions/checkout@*
      actions/upload-artifact@*
      actions/download-artifact@*

Fork pull request workflows from outside collaborators:
  ◉ Require approval for first-time contributors
    (este é o item crítico — mantenedor aprova antes de runner pegar
     PR de pessoa que nunca contribuiu)

Workflow permissions:
  ◉ Read repository contents and packages permissions
    (default seguro; jobs precisam declarar permissões maiores explicitamente)
```

#### 2.4. Self-hosted runner permissions

```
Settings → Actions → Runners → <runner name>
  ☑ Disable this runner from picking up jobs from public repos
    (relevante quando repo virar público; agora não tem efeito)

Settings → Actions → Runner groups → Default
  ◉ Restrict to specific repositories: tertoos
    (evita runner pegar jobs de outros repos da org)
```

#### 2.5. Secrets

Use **Repository secrets** (não Environment) para:
- Tokens externos (signing key, S3 upload, etc.)
- **NUNCA** o token do GH PAT — Actions usa `GITHUB_TOKEN` automático.

```
Settings → Secrets and variables → Actions → New repository secret
```

Acesso a secrets em workflow:
```yaml
env:
  MY_TOKEN: ${{ secrets.MY_TOKEN }}
```

⚠️ Secrets **não são acessíveis** em jobs de fork PRs (proteção
built-in). NÃO usar `pull_request_target` (que expõe secrets em
fork context — vetor conhecido de leak).

#### 2.6. Webhooks e logs

Periodicamente:
```
Settings → Webhooks → ver eventos recentes
Insights → Network / Forks (se público)
Security → Code scanning alerts
```

---

## Nível 3 — Rede (LAN com NAT)

Você mencionou IP privado com acesso à internet via NAT — isso já é
**baseline forte** de segurança. Vamos formalizar o que fica
implícito + o que adicionar.

### O que NAT já te protege

- ✅ Inbound da internet: bloqueado por default no router NAT (sem
  port forward configurado, atacante externo não chega na DL360).
- ✅ Visibilidade externa: zero — IP público do router não revela
  nada sobre a DL360.

### O que NAT NÃO protege

- ❌ Inbound da LAN: qualquer device da mesma rede pode tentar ssh.
- ❌ Workstation comprometida na LAN → ssh-via-key copiado.
- ❌ Outbound: DL360 acessa qualquer IP/porta — se alguma vulnerabilidade
  rodar processo, ele liga pra C2 sem dificuldade.

### Recomendações de rede

#### 3.1. Segregação LAN (se possível)

Ideal: DL360 + iLO em VLAN/subnet **dedicada** com regras de firewall:
- LAN dev → DL360: SSH (port 22) only, idealmente de IPs específicos.
- DL360 → LAN dev: bloqueado (DL360 não precisa iniciar conexão pra
  workstations).
- DL360 → internet: allow (apt, github, docker registry).
- iLO em rede out-of-band, não acessível da internet de forma alguma.

Se você tem firewall doméstico/edge gerenciável (pfSense, OPNsense,
MikroTik, Ubiquiti), criar regras assim. Se rede é flat residencial
sem segmentação, item 3.2 mitiga.

#### 3.2. Se rede é flat (residencial sem VLAN)

Aceito. Mitigações alternativas:

- UFW da DL360 (já feito por harden.sh) bloqueia tudo exceto SSH.
- SSH key-only auth (harden.sh aplica se chave estiver setada).
- iLO **DESCONECTADO da rede principal** — ou ligado em port direto
  com cabo cruzado pro laptop quando precisar acessar (não em rede
  full-time). Se precisar full-time, pelo menos password complexo +
  HTTPS only + filtrado por IP.

#### 3.3. iLO específico

iLO Gen9 tem histórico de CVEs. Se acessível na rede:

- ✅ Update firmware iLO para latest stable.
- ✅ Trocar password default (qualquer Gen9 sai com `Administrator/<8 char na etiqueta>`).
- ✅ Desabilitar HTTP (manter só HTTPS).
- ✅ Desabilitar IPMI over LAN se não usar.
- ✅ Restringir IPs autorizados (iLO Settings → Access Settings → Authorized SSL Cert + IP ACL).
- ⚠️ **Não exponha iLO à internet em hipótese alguma** — Gen9 iLO 4 tem
  CVEs documentadas (CVE-2017-12542 etc.) que dão RCE remoto.

#### 3.4. NAT outbound (paranoid mode opcional)

Se quiser fechar mais o loop, configurar firewall NAT para limitar
outbound da DL360 a:
- `*.github.com` (api, codeload, etc.)
- `*.actions.githubusercontent.com`
- `*.docker.io`, `*.docker.com`
- Apt mirrors (`*.ubuntu.com`, `archive.canonical.com`)
- TLS em portas 443 e 80 (apt)

Implementação no firewall edge — não no DL360 (preferível, pois
processo malicioso rodando como root no DL360 poderia desabilitar
UFW local; firewall externo independente).

Considerar **paranoid** apenas se ataque GH workflow for vetor
realístico no seu cenário. Para release v0.1 não vale o overhead.

---

## Manutenção do runner GitHub Actions

### Update do runner agent (trimestral)

Runner versão fica desatualizada e pode ter CVEs próprios.
Procedimento:

```bash
ssh build@<DL360-IP>
cd ~/actions-runner

# 1. Stop service
sudo ./svc.sh stop

# 2. Verificar latest version
LATEST=$(curl -s https://api.github.com/repos/actions/runner/releases/latest \
         | jq -r '.tag_name | sub("^v"; "")')
echo "Latest: $LATEST"

# 3. Download + extract
curl -fsSL -o runner-update.tar.gz \
    "https://github.com/actions/runner/releases/download/v${LATEST}/actions-runner-linux-x64-${LATEST}.tar.gz"
tar xzf runner-update.tar.gz --strip-components=0
rm runner-update.tar.gz

# 4. Restart service
sudo ./svc.sh start
sudo ./svc.sh status
```

GH Actions web UI → Settings → Actions → Runners deve mostrar versão
atualizada.

### Rotate token (anual ou ao mudar mantenedor)

Tokens não expiram automaticamente, mas é boa prática rotate. Em
rotação:

```bash
# 1. No GitHub: gerar novo runner registration token
# 2. Na DL360:
cd ~/actions-runner
sudo ./svc.sh stop
./config.sh remove --token <novo-token>
./config.sh --url https://github.com/terto-networks/tertoos --token <novo-token> --name <name> --labels self-hosted,tertoos-build,dl360
sudo ./svc.sh install
sudo ./svc.sh start
```

### Audit periódico

Mensal, conferir:

```bash
# Logs do runner
journalctl -u 'actions.runner.*' --since '30 days ago' | grep -iE 'error|fail|denied'

# Workflows que rodaram
gh run list --limit 50

# Runner status
gh api /repos/terto-networks/tertoos/actions/runners --jq '.runners[] | {name, status, busy, labels: [.labels[].name]}'
```

Padrões suspeitos:
- Workflow rodado por usuário desconhecido.
- Runner com status `offline` quando deveria estar `online` (alguém
  parou).
- Branches/refs estranhas em runs.

---

## Checklist resumido

Use este checklist quando montar a DL360 amanhã. Cada ✅ = tarefa
concluída.

### OS (na DL360)
- [ ] Ubuntu 22.04 LTS instalado, user `build` criado
- [ ] `sudo ./build-machine/setup.sh` rodou (performance setup)
- [ ] Reboot pós-setup, `validate.sh` retorna verde
- [ ] SSH key do laptop adicionada: `ssh-copy-id build@DL360`
- [ ] Login via key funciona (sem password prompt)
- [ ] `sudo ./build-machine/harden.sh` rodou (security hardening)
- [ ] Validar: `sudo ufw status` mostra SSH allowed + default deny
- [ ] Validar: `sudo fail2ban-client status sshd` mostra jail ativo
- [ ] iLO firmware atualizado, password trocado, HTTP off

### GitHub repo `tertoos`
- [ ] Repo está **privado** (até v0.1 sair)
- [ ] Branch protection em `master`: PR + 1 review + CI green required
- [ ] Settings → Actions → "Require approval for first-time contributors" ☑
- [ ] Allowed actions: GitHub-owned + verified marketplace + lista whitelist específica
- [ ] Runner registrado: visível em Settings → Actions → Runners

### Rede
- [ ] DL360 em IP privado atrás de NAT (já é o caso)
- [ ] iLO em network out-of-band ou pelo menos firewall isolado
- [ ] iLO **NÃO** acessível da internet (testar de fora)
- [ ] Workstation dev tem ssh key, não usa password
- [ ] Roteador edge não tem port forwarding para DL360 (verificar)

### Manutenção (agendar)
- [ ] Cron mensal: `apt full-upgrade` + reboot janela manutenção
- [ ] Cron trimestral: update runner agent
- [ ] Cron mensal: review fail2ban + auth.log
- [ ] Anual: rotate SSH keys + GitHub tokens

---

## TL;DR — o que fazer amanhã

```bash
# Passos 1-3 são o caminho feliz, em ordem.

# 1. Setup performance (já documentado em BUILD-MACHINE-SETUP.md)
sudo ./setup.sh
sudo reboot
sudo ./validate.sh   # confere setup

# 2. Adicionar SSH key e hardening
# Do laptop:
ssh-copy-id -i ~/.ssh/id_ed25519.pub build@<DL360-IP>
ssh build@<DL360-IP> 'echo "key works"'   # confirma

# Na DL360:
sudo ./harden.sh --yes   # aplica hardening completo (key detected)

# 3. Registrar runner
# Browser: https://github.com/terto-networks/tertoos/settings/actions/runners/new
# Copia token

sudo RUNNER_TOKEN=<token> ./register-runner.sh

# 4. Settings GitHub UI (uma vez):
#    - Repo Settings → General → mantém Private
#    - Settings → Branches → Add protection rule master
#    - Settings → Actions → "Require approval for first-time contributors"
```

Pronto. Pipeline + segurança em 4 passos.
