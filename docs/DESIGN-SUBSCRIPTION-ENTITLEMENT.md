# Design — Subscription / Entitlement (no papel)

> Desenho técnico da camada de licenciamento do TertoOS Horizon. **Não é
> implementação** — é o blueprint pra discutir antes de codar. Baseado na estratégia
> open-core (ver `ESTRATEGIA-LICENCIAMENTO-TERTOOS.md`). Reaproveita a infra existente:
> Core multi-tenant, PKI (CA + mTLS + CRL), phone-home NATS, serial por switch, OTA.

---

## 1. Princípios de design

1. **Enforcement no Core, não no device.** O Core já controla push de config, telemetria e
   OTA. Sem assinatura → sem gerência; sem feature no plano → Core não empurra a config. A
   validação no agent (token assinado) é **defesa em profundidade / modo offline**, não
   requisito da v1.
2. **Soft enforcement — nunca brica.** Estados de assinatura degradam suavemente; tráfego
   existente nunca cai.
3. **Reuso da PKI.** O license token é assinado pela **mesma CA** que assina os certs mTLS —
   é o mesmo padrão do `cert.revoked` (S13.B.5) e do CRL pull (S13.B.4).
4. **Billing plugável.** Pagamento é uma porta (`IBillingGateway`); na v1 a implementação é
   `NullBilling` (tudo free).
5. **Simples primeiro.** Um preço por device gerenciado, tudo incluso. Sem tiers complexos.

---

## 2. Modelo de dados

### 2.1 Entidades (no Core / Postgres)

```
Plan (catálogo — poucas linhas fixas)
 ├─ Code            string  PK   ("free", "managed")
 ├─ Name            string       ("Free", "Gerenciado")
 ├─ DeviceLimit     int          (free=3; managed=null/ilimitado)
 ├─ Features        string[]     (features liberadas; ver §3)
 ├─ PricePerDevice  decimal?     (free=0; managed=preço — pode ficar null por ora)
 └─ IsDefault       bool         (free=true → novo tenant cai aqui)

Subscription (1 por tenant)            [MultiTenant]
 ├─ Id              Guid    PK
 ├─ TenantId        string  FK→tenant  (unique: 1 ativa por tenant)
 ├─ PlanCode        string  FK→Plan
 ├─ Status          enum         (active | grace | suspended)
 ├─ DeviceLimit     int          (cópia do plano no momento; permite override comercial)
 ├─ Features        string[]     (cópia/override do plano)
 ├─ CurrentPeriodEnd DateTimeOffset?  (null = free permanente)
 ├─ GraceUntil      DateTimeOffset?
 ├─ ExternalRef     string?      (id da assinatura no gateway de pagamento — futuro)
 ├─ CreatedAt / UpdatedAt
 └─ (derivado) ManagedDeviceCount = COUNT(switches WHERE TenantId=...)

LicenseToken (opcional v1 — p/ device-side / offline)
 ├─ assinado pela CA: JWT { tenant, serial, features[], plan, nbf, exp }
 ├─ não precisa persistir; é gerado on-demand e entregue ao agent
 └─ agent valida com a public key da CA (já embarcada)
```

### 2.2 Diagrama de relacionamento

```
        ┌──────────┐        ┌────────────────┐        ┌─────────────┐
        │  Plan    │ 1    * │  Subscription  │ 1    1 │   Tenant    │
        │ (free,   ├───────►│  (status,      ├───────►│  (acme,...) │
        │ managed) │        │   limit, feat) │        └──────┬──────┘
        └──────────┘        └────────────────┘               │ 1
                                                              │
                                                              │ *
                                                       ┌──────▼──────┐
                                                       │  Switch     │  (já existe)
                                                       │  (serial)   │
                                                       └─────────────┘
   Entitlement de um switch = (Subscription.Status ∈ {active,grace})
                              AND (ManagedDeviceCount ≤ DeviceLimit)
                              AND (feature ∈ Subscription.Features)
```

> Nota: **Entitlement não vira tabela na v1** — é uma *função* sobre a Subscription + contagem
> de switches. Vira tabela só se/quando precisar de license token por device persistido.

---

## 3. Catálogo de features (o que é "premium")

```
free      : l2, ospf, bgp-basic, cli-local, horizon-manage(≤ DeviceLimit)
premium   : sr-mpls, sr-te, l3vpn, evpn-vxlan, telemetry-advanced, ota, multi-site
```

Cada operação de config no Core declara qual feature exige. Ex.: aplicar uma config de L3VPN
→ requer `l3vpn` ∈ `Subscription.Features`.

---

## 4. Máquina de estados da Subscription

```
                 período vence
   ┌────────┐  (CurrentPeriodEnd)   ┌────────┐   GraceUntil vence   ┌───────────┐
   │ active │ ───────────────────►  │ grace  │ ───────────────────► │ suspended │
   └────────┘                       └────────┘                      └───────────┘
       ▲                                 │                                │
       │       pagamento / renovação     │      pagamento / upgrade       │
       └─────────────────────────────────┴────────────────────────────────┘

  active    : tudo liberado dentro do plano.
  grace     : tudo ainda funciona + ALERTA. (janela de cortesia, ex. 30-60 dias)
  suspended : bloqueia MUDANÇA de config premium e NOVOS enrollments.
              NUNCA derruba tráfego nem remove config que já está rodando.
```

---

## 5. Fluxos principais

### 5.1 Criação de tenant → subscription free automática

```
Admin cria tenant "acme"
   └─► Core cria Subscription{ tenant=acme, plan=free, status=active,
                               deviceLimit=3, features=[base], periodEnd=null }
```

### 5.2 Enrollment de switch (gate de contagem)

```
Switch novo tenta enrollar (já passa pela PKI/mTLS existente)
   └─► Core: ManagedDeviceCount < DeviceLimit ?
         ├─ sim  → enroll OK
         └─ não  → SOFT: enroll permitido porém marcado "over-limit" + alerta no painel
                   (ou bloqueio, conforme política — recomendo soft no início)
```

### 5.3 Push de config (gate de feature) — o enforcement principal

```
Operador aplica config (ApplyConfig no Core)
   └─► Core resolve as features exigidas pela config
         └─► todas ∈ Subscription.Features  AND  status ∈ {active, grace} ?
               ├─ sim  → renderiza + empurra (fluxo atual, intacto)
               └─ não  → REJEITA com erro claro:
                         "Feature 'l3vpn' requer plano Gerenciado. Faça upgrade."
                         (config existente no switch NÃO é tocada)
```

### 5.4 License token (defesa em profundidade / offline) — opcional v1

```
Core (on-demand)                          Agent no switch
  assina JWT com a CA  ──push NATS──►   recebe (subject .license.updated,
  { tenant, serial,     ──ou pull──►     espelha cert.revoked / CRL)
    features, exp }                       │
                                          ├─ valida assinatura (CA pubkey embarcada)
                                          ├─ confere serial == próprio
                                          ├─ reporta status no heartbeat
                                          └─ (futuro) gate local de feature, soft
```

### 5.5 Billing (futuro) — webhook ajusta a subscription

```
Gateway (Asaas/Stripe) ──webhook──► IBillingGateway.HandleWebhook(evt)
   evt = pagamento ok       → Subscription.status=active, periodEnd=+1 mês
   evt = falha/cancel       → status=grace (inicia GraceUntil)
```

---

## 6. Onde isso encaixa no código existente (reuso)

| Peça nova | Onde pluga | Reaproveita |
|---|---|---|
| `Plan`, `Subscription` (EF) | `Core.Infrastructure/Persistence` | padrão das entities `[MultiTenant]` |
| Gate de contagem | handler de enrollment | tabela `switches` já conta |
| Gate de feature | `ApplyConfigHandler` | ponto único de push já existe |
| License token | novo `LicenseSigner` | CA + padrão `cert.revoked` (S13.B.5) |
| Push/pull do token | NATS subjects | espelha CRL pull (S13.B.4) |
| `IBillingGateway` (porta) | `Core.Application` | `NullBilling` agora; gateway depois |
| UI "Planos / Licenças" | nova page na admin UI | estende o painel AmpCon recém-feito |

---

## 7. Superfície de API / UI (esboço)

```
Admin (super-admin):
  GET    /admin/plans
  GET    /admin/tenants/{id}/subscription
  PUT    /admin/tenants/{id}/subscription      (mudar plano/limite — manual por ora)
  GET    /admin/tenants/{id}/usage             (devices usados / limite, features)

UI (estende a admin atual):
  página "Planos & Licenças": por tenant → plano, status, devices X/limite,
  features liberadas, botão de upgrade (futuro: leva ao checkout).
```

---

## 8. O que NÃO entra na v1 (deferimentos conscientes)

- **Pagamento real** (só a porta `IBillingGateway` + `NullBilling`).
- **Tiers múltiplos** (só `free` + `managed`).
- **Gate de feature no agent** (Core basta; agent só reporta).
- **Cobrança por capacidade/throughput**.
- **License token persistido por device** (gerado on-demand; só vira tabela se precisar offline).
- **Medição/metering de uso** pra cobrança variável.

---

## 9. Sequência sugerida de implementação (quando for a hora)

```
1. Entities Plan + Subscription + migration; seed do plano "free" (default).
2. Auto-criar Subscription free ao criar tenant.
3. Gate de contagem no enrollment (soft) + página de uso na UI.
4. Catálogo de features + gate no ApplyConfigHandler (o enforcement que dá dinheiro).
5. UI "Planos & Licenças".
6. (opcional) LicenseSigner + push/pull pro agent.
7. (futuro) IBillingGateway real (Asaas/Stripe) + checkout.
```

> Estimativa grosseira: passos 1-5 são o "base pronta pra cobrar" — sem cobrar ainda.
> Passo 7 é o "ligar a torneira".
