# Estratégia de Licenciamento do TertoOS (for dummies)

> Documento de referência e pitch. Explica **como o TertoOS vai ganhar dinheiro**
> sem cobrar pelo sistema operacional em si. Linguagem simples de propósito.
> Decisão tomada em 2026-05-22. Estágio: **estratégia fechada, nada implementado ainda.**

---

## Em uma frase

**O TertoOS (o sistema do switch) é grátis. Você cobra pela *gerência* (o Horizon) e
pelas *features avançadas*.** Quanto mais switches o cliente gerencia de forma
centralizada, mais ele paga.

---

## A analogia "for dummies"

Pense no **WhatsApp**: o aplicativo é grátis pra qualquer um. Mas a versão de
**empresa** (WhatsApp Business API), com central de atendimento, automações e
gerenciamento de muitos números, é paga.

No TertoOS é igual:
- **O switch funciona 100% de graça** — liga, configura pela CLI, roteia tráfego. Um ISP
  pequeno pode rodar a rede inteira sem pagar nada.
- **Quando ele quer gerenciar tudo de um lugar só** (vários switches, telemetria, push de
  config, atualização remota) — aí entra o **Horizon**, que é pago.

---

## O que é grátis e o que é pago

| Item | O que é | Preço |
|---|---|---|
| **TertoOS** (o NOS) | A imagem do switch. CLI, L2, OSPF, BGP básico, roteamento | **Grátis / aberto** |
| **Horizon** (gerência) | Painel central: configurar, monitorar, atualizar e detectar mudança em vários switches | **Pago, por switch gerenciado** |
| **Features avançadas** | SR-TE, L3VPN, EVPN-VXLAN, telemetria detalhada | Liberadas no plano pago |
| **Suporte / SLA** | Atendimento prioritário em português | Pacote à parte |

> O "free" ainda inclui o Horizon para **poucos switches** (sugestão: até 3). Isso é o
> "anzol": o cliente entra no ecossistema sem pagar e, quando a rede dele cresce, vira pagante
> naturalmente.

---

## Por que esse caminho é o melhor (3 razões)

1. **O valor de vocês não está no protocolo — está na operação.** OSPF, BGP e MPLS vêm do
   FRR, que é software livre. Ninguém paga por isso. O que diferencia o TertoOS é a
   **integração testada + gerência + suporte em português + hardware nacional**. Cobrar pela
   gerência é cobrar pelo que de fato vale.
2. **Adoção primeiro, receita depois.** NOS grátis tira a barreira de entrada — o cliente
   testa sem comprar nada. Quando precisa escalar, paga. Esse funil cresce sozinho.
3. **Resolve a parte jurídica.** O TertoOS usa peças com licença **GPL** (o FRR, partes do
   kernel) que obrigam a publicar o código-fonte delas. Como você **não cobra pelo binário**,
   essa obrigação vira trivial e não atrapalha o negócio. (Ver seção GPL abaixo.)

---

## Como o controle funciona (a parte esperta)

Aqui está o pulo do gato: **o ponto de cobrança já existe.** O Horizon (chamado de "Core") é
quem empurra a configuração, recebe a telemetria e faz a atualização dos switches. Logo:

```
Sem assinatura  →  sem gerência centralizada.
Plano free      →  gerencia poucos switches, features básicas.
Plano pago      →  gerencia muitos switches + libera features avançadas.
```

E mais: se o cliente não tem o plano que libera, por exemplo, **L3VPN**, o Core
**simplesmente não empurra** essa configuração — então a feature nem liga no switch. O controle
acontece de graça, dentro do fluxo que já funciona. Não precisa "trancar" o binário.

---

## As regras de ouro (inegociáveis)

1. **NUNCA derrubar o tráfego do cliente.** Esse é um produto de ISP/telco. Se a licença
   vencer, o switch **continua roteando**. O que acontece é: aparece um alerta, e o cliente
   fica impedido de fazer *mudanças* em features pagas — mas o que já está rodando, continua.
   Derrubar a rede de um cliente por causa de licença = processo na justiça. Jamais.
2. **Período de tolerância (grace period) generoso** — ex.: 30 a 60 dias após o vencimento,
   com avisos aumentando de tom.
3. **Otimizar para o cliente honesto.** 90% das pessoas só perdem o controle de licenças sem
   má-fé. A experiência tem que ser boa pra elas. Contra o pirata determinado não vale gastar
   energia — não dá pra impedir, e ele perde justamente o que tem valor (gerência, suporte,
   atualizações).

---

## Sobre a parte jurídica (GPL) — resumo

> ⚠️ Isto é a explicação técnica das licenças (fato consolidado). O contrato comercial em si
> pede um advogado de propriedade intelectual.

- **Seu código** (Horizon, agent, CLI customizada, renderers) é **proprietário** — você
  controla.
- **As peças GPL** (FRR, módulos do kernel) **exigem** que você ofereça o código-fonte delas.
  Solução: um portal/repositório público com esses fontes. Pronto, obrigação cumprida.
- **Cobrar por produto baseado em GPL é legal e comum** — Red Hat, SUSE e a antiga Cumulus
  fazem isso há décadas. Você vende o **produto integrado + gerência + suporte**, não a
  exclusividade sobre o pedaço GPL.

---

## Quando formos cobrar (e por que dá pra esperar)

A ideia é construir **toda a base de licenciamento agora**, mas deixar o **pagamento como uma
"tomada" que se pluga depois**:

- **Hoje:** todo cliente entra no plano free. Tudo funciona. Ninguém paga.
- **Quando decidir cobrar:** conecta um meio de pagamento e define o preço. **Sem reescrever
  nada.**
- **Meios de pagamento (Brasil):** Asaas, Iugu, Vindi, Pagar.me (recorrência, PIX, boleto,
  nota fiscal). Internacional: Stripe.

---

## Perguntas frequentes

**E se o cliente copiar a imagem para um switch sem licença?**
O switch funciona (é grátis mesmo). Mas ele **não consegue gerenciar pelo Horizon** nem ligar
features pagas sem assinatura. O valor está no serviço, não no arquivo.

**Isso não é dar o produto de graça?**
Não. É dar a **porta de entrada** de graça. O dinheiro vem de quem cresce e precisa de escala,
gerência e suporte — exatamente quem tem capacidade de pagar.

**Por que não cobrar por velocidade de porta (1G/10G/100G)?**
Mais complexo de medir e justificar agora. Começamos **simples**: um preço por switch
gerenciado, tudo incluso. Modelos mais sofisticados entram depois, se o mercado pedir.

**Como é a contagem de switches?**
O Horizon já sabe quantos switches cada cliente tem cadastrado (tabela `switches`). O plano
define o limite. Acima do limite: bloqueia novo cadastro (de forma suave) ou pede upgrade.

---

## Glossário

- **NOS** — Network Operating System (o sistema do switch). No nosso caso, o TertoOS.
- **Horizon / Core** — a plataforma central (SaaS) que gerencia os switches.
- **Tenant** — um cliente/organização isolada dentro do Horizon (cada ISP é um tenant).
- **Open-core** — modelo onde o núcleo é aberto/grátis e os extras/gerência são pagos.
- **Entitlement** — o "direito de uso": o que aquele cliente/switch pode fazer.
- **Grace period** — período de tolerância após o vencimento, sem cortar o serviço.
- **GPL** — licença de software livre que obriga a compartilhar o código-fonte.
