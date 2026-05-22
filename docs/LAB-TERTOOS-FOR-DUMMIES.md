# Laboratório TertoOS — Guia "for dummies"

> **O que é isto:** um passo a passo, em nível de iniciante, para subir e operar o
> laboratório do TertoOS — o nosso NOS (Network Operating System) baseado em SONiC,
> posicionado como **roteador de agregação / PE** para provedores.
>
> **Estágio (honesto):** tudo aqui é **laboratório / simulador**. Não é produção. O
> encaminhamento do "fio L2" (L2 Circuit) em produção é nativo do silício (Centec); no
> laboratório usamos um *simulacro* de software (explicado no §8).

---

## 1. O que o laboratório prova

Com 4 roteadores TertoOS (PE = Provider Edge) o lab demonstra, **tudo configurado pela
CLI estilo IOS-XR (klish)**:

| Recurso | O que é (em uma frase) |
|---|---|
| **SR-MPLS** | MPLS com Segment Routing — cada roteador tem um "número" (node-SID) e o caminho é uma pilha de labels. |
| **BGP** | O protocolo que troca rotas entre roteadores. |
| **BGP Route Reflector (RR)** | Um roteador central que "reflete" rotas, evitando que todos falem com todos. |
| **BGP communities** | "Etiquetas" nas rotas para aplicar políticas (ex.: não exportar, mudar preferência). |
| **L2 Circuit / fio L2 (VPWS)** | Um "cabo virtual" que leva Ethernet do cliente de um PE a outro por cima do MPLS. |

---

## 2. Topologia

```
                 (cliente PPPoE)                         (BRAS PPPoE)
                      CPE                                    BRAS
                       │ br-cpe                       br-bras │
                       │                                      │
                  ┌────┴────┐    10.0.12.0/30    ┌────────────┴┐
                  │   PE1   │────────────────────│     PE2     │
                  │ .255.0.1│  Eth4         Eth0 │  .255.0.2   │
                  └────┬────┘                    └──────┬──────┘
              10.0.13.0/30 Eth8              Eth4 10.0.24.0/30
                       │                                │
                  ┌────┴────┐                    ┌──────┴──────┐
                  │   PE3   │────────────────────│     PE4     │
                  │ .255.0.3│  Eth4   10.0.34.0/30  .255.0.4   │
                  └─────────┘  Eth0          Eth8 └─────────────┘
```

**Nós:**

| Nó | Imagem | Loopback (router-id) | node-SID |
|---|---|---|---|
| PE1 | TertoOS (sonic-vs) | 10.255.0.1 | 16001 |
| PE2 | TertoOS (sonic-vs) | 10.255.0.2 | 16002 |
| PE3 | TertoOS (sonic-vs) | 10.255.0.3 | 16003 |
| PE4 | TertoOS (sonic-vs) | 10.255.0.4 | 16004 |
| CPE | MikroTik CHR | — | cliente PPPoE (atrás do PE1) |
| BRAS | MikroTik CHR | — | servidor PPPoE (atrás do PE4) |

**Links (de núcleo) e portas SONiC:**

| Link | Sub-rede | Ponta A | Ponta B |
|---|---|---|---|
| PE1 ↔ PE2 | 10.0.12.0/30 | PE1 Ethernet4 (.1) | PE2 Ethernet0 (.2) |
| PE1 ↔ PE3 | 10.0.13.0/30 | PE1 Ethernet8 (.1) | PE3 Ethernet0 (.2) |
| PE2 ↔ PE4 | 10.0.24.0/30 | PE2 Ethernet4 (.1) | PE4 Ethernet4 (.2) |
| PE3 ↔ PE4 | 10.0.34.0/30 | PE3 Ethernet4 (.1) | PE4 Ethernet8 (.2) |
| PE1 ↔ CPE | acesso | PE1 Ethernet0 (br-cpe) | CPE ether2 |
| PE4 ↔ BRAS | acesso | PE4 Ethernet0 (br-bras) | BRAS ether2 |

> **Importante (PE1↔PE4 não são vizinhos diretos):** o caminho PE1→PE4 passa por PE2 *ou*
> PE3 (ECMP). É por isso que o "fio L2" entre eles é **multi-hop** (§8).

**Credenciais padrão:** usuário `admin`, senha `tos`. Hostname `tertoos`.

---

## 3. Onde o lab roda

- **Servidor de build/sim:** `build@192.168.0.123` (Linux, KVM/QEMU).
- **Repositório:** `/dados/tertoos` (no servidor) — branch da release `v0.5.0`.
- **Scripts do sim:** `src/terto-horizon/sim/canonical-mpls/`.
- **Acesso aos PEs:** SSH via porta local no servidor — PE1=2201, PE2=2202, PE3=2203,
  PE4=2204, CPE=2210, BRAS=2211. Exemplo de PE1:
  ```bash
  ssh build@192.168.0.123
  sshpass -p tos ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -p 2201 admin@127.0.0.1
  ```
  > Após um boot novo, as chaves SSH dos PEs mudam — por isso o `UserKnownHostsFile=/dev/null`.

---

## 4. Subir o laboratório (o jeito fácil)

No servidor, dentro de `src/terto-horizon/sim/canonical-mpls`:

```bash
cd /dados/tertoos/src/terto-horizon/sim/canonical-mpls

make up          # cria as bridges + sobe as 6 VMs (PE1-4 + CPE + BRAS)
# aguarde ~8-10 min o SONiC bootar e os containers subirem

make status      # mostra VMs, bridges e links
```

**Smoke completo de SR-MPLS pela CLI (recomendado p/ validar):**
```bash
TERTOOS_ADMIN_PASS=tos make smoke-sr-klish
# bootstrap (limpa minigraph + habilita FRR) -> configura SR via klish -> roda a suíte
# resultado esperado: PASS 20  FAIL 0
```

Outros alvos úteis:
```bash
make bootstrap   # só prepara os PEs (limpa config de exemplo + habilita daemons FRR)
make sr-klish    # só configura SR-MPLS via klish (sem a suíte)
make down        # derruba as VMs e remove as bridges
make help        # lista todos os alvos
```

---

## 5. Configurar pela CLI (klish, estilo IOS-XR) — passo a passo

Entre num PE (ex.: PE1) e na CLI:
```bash
sshpass -p tos ssh ... -p 2201 admin@127.0.0.1     # cai direto na CLI "tertoos>"
enable
configure terminal
```

### 5.1 SR-MPLS (resumo — o `make sr-klish` já faz isto)
Cada PE habilita OSPF com Segment Routing e um prefix-SID no Loopback0. (Automatizado
pelos scripts; aqui fica o conceito: OSPF na interface + `segment-routing` global + SRGB
16000–23999 + prefix-SID por loopback.)

### 5.2 BGP + Route Reflector
**No PE1 (o Route Reflector):**
```
router bgp 65000
 bgp router-id 10.255.0.1
 address-family ipv4 unicast
  network 10.255.0.1/32
  exit
 neighbor 10.255.0.2
  remote-as 65000
  update-source Loopback0
  address-family ipv4 unicast
   route-reflector-client
   exit
  exit
 neighbor 10.255.0.3
  remote-as 65000
  update-source Loopback0
  address-family ipv4 unicast
   route-reflector-client
   exit
  exit
 neighbor 10.255.0.4
  remote-as 65000
  update-source Loopback0
  address-family ipv4 unicast
   route-reflector-client
   exit
  exit
 exit
exit
commit
end
```

**Nos clientes (PE2, PE3, PE4) — exemplo PE2:**
```
configure terminal
router bgp 65000
 bgp router-id 10.255.0.2
 address-family ipv4 unicast
  network 10.255.0.2/32
  exit
 neighbor 10.255.0.1
  remote-as 65000
  update-source Loopback0
  address-family ipv4 unicast
   exit
  exit
 exit
exit
commit
end
```

**Verificar (no FRR, dentro do container bgp):**
```bash
docker exec bgp vtysh -c "show bgp ipv4 unicast summary"   # sessões Established
```

### 5.3 BGP communities (set + match + política)
**No PE2 — etiquetar as rotas anunciadas com a community 65000:100:**
```
configure terminal
route-policy SET-COMM
 permit 10
 set community 10 65000:100
 exit
router bgp 65000
 neighbor 10.255.0.1
  address-family ipv4 unicast
   send-community standard
   route-policy out SET-COMM
   exit
  exit
 exit
exit
commit
end
```

**No PE1 (RR) — casar a community e mudar a preferência:**
```
configure terminal
community-set CS-P2
 member 65000:100
 exit
route-policy CHK-COMM
 permit 10
 match community 10 CS-P2
 set local-preference 10 300
 permit 20
 exit
router bgp 65000
 neighbor 10.255.0.2
  address-family ipv4 unicast
   route-policy in CHK-COMM
   exit
  exit
 exit
exit
commit
end
```

**Verificar (no PE1 ou PE3):**
```bash
docker exec bgp vtysh -c "show bgp ipv4 unicast 172.16.2.0/24"
# deve mostrar: Community: 65000:100, localpref 300, Originator/Cluster list (refletido)
```

---

## 6. Smoke test: forçar um caminho no SR (SR-TE)

Mostra que dá para **pinar um fluxo num caminho específico** (em vez do ECMP). Forçamos o
mesmo destino (10.99.99.4 no PE4) primeiro via PE2, depois via PE3.

```bash
# no PE4: cria um destino de teste
ip addr add 10.99.99.4/32 dev lo

# no PE1: força via PE2 (label do PE4 = 16004, next-hop = PE2)
ip route replace 10.99.99.4/32 encap mpls 16004 via 10.0.12.2 dev Ethernet4
ping -c 5 -I 10.255.0.1 10.99.99.4

# no PE1: força via PE3
ip route replace 10.99.99.4/32 encap mpls 16004 via 10.0.13.2 dev Ethernet8
ping -c 5 -I 10.255.0.1 10.99.99.4

# verificar no PE4 (qual interface recebe): Ethernet4=de PE2, Ethernet8=de PE3
tcpdump -nni Ethernet4 host 10.99.99.4   # vê tráfego quando forçado via PE2
tcpdump -nni Ethernet8 host 10.99.99.4   # vê tráfego quando forçado via PE3
```
> **Detalhe:** o penúltimo salto remove o label (PHP), então no PE4 o pacote chega como IP
> puro — por isso filtramos por `host`, não por `mpls`. Resultado provado: 100% do fluxo
> migra para o caminho forçado.

---

## 7. Cenário canônico: PPPoE pelo fio L2 (OLT/ONU → BRAS)

O CPE (atrás do PE1) disca PPPoE; a BRAS (atrás do PE4) termina. O "fio L2" leva o PPPoE
de PE1 a PE4 por cima do MPLS. Os CHR (MikroTik) já trazem PPPoE; os scripts configuram:
```bash
make build-chr      # baixa a imagem CHR (uma vez)
# após 'make up', rodar a config dos CHR (PPPoE no access port = ether2):
scripts/cpe-chr-up.sh  topology.yml /tmp/tertoos-sim
scripts/bras-chr-up.sh topology.yml /tmp/tertoos-sim
```
**Resultado provado:** o CPE recebe um IP da pool da BRAS e o ping CPE→BRAS passa 0% loss,
atravessando o fio L2.

---

## 8. O "fio L2" no simulador (simulacro de data plane) — §avançado

No hardware real (Centec) o pseudowire (fio L2) é nativo do silício. No SONiC-VS o objeto
de pseudowire **não tem data plane**, então usamos um *sidecar* de software (`tos-vpws-sim`,
em `vpws-sidecar/`) que lê o `CONFIG_DB` e encaminha o quadro Ethernet do cliente por cima
do MPLS. **É VS-only** — não entra na build de silício.

Configuração mínima de um PW (escrita no CONFIG_DB; o klish escreve a mesma tabela):
```bash
# em cada PE, com o sidecar rodando:
redis-cli -n 4 hset 'L2VPN_XCONNECT_GROUP|G1|P1' \
    interface <porta-acesso> peer-address <loopback-do-PE-remoto> pw-id 100
sudo /tmp/tos-vpws-sim &     # observa o CONFIG_DB e realiza o(s) PW(s)
```
Detalhes e fases (0 a 3) em `src/terto-horizon/sim/canonical-mpls/vpws-sidecar/README.md`.

---

## 9. Resolução de problemas (rápido)

| Sintoma | Causa provável | O quê fazer |
|---|---|---|
| SSH "REMOTE HOST IDENTIFICATION CHANGED" | boot novo regenerou as chaves | use `-o UserKnownHostsFile=/dev/null` ou limpe o `known_hosts` |
| `make bootstrap` falha pedindo senha | senha do sim diferente do default | `TERTOOS_ADMIN_PASS=tos make ...` |
| Sessão BGP fica `Idle`/`Active` | neighbor não ativado / NHT não resolveu | confira `address-family ipv4 unicast` no neighbor; aguarde OSPF convergir |
| Config some ao reconfigurar via klish | sonic-vs perde eventos do frrcfgd | `docker exec bgp supervisorctl restart frrcfgd` (re-renderiza limpo) |
| `network 10.0.0.0/24` vira /32 | (corrigido na v0.5.0) | use a imagem v0.5.0 |

---

## 10. Versão

Release **TertoOS v0.5.0 (labs)** — primeira release de laboratório com o plano de gerência
(klish) dirigindo SR-MPLS, BGP/RR, communities e o simulacro do fio L2.
GitHub: https://github.com/terto-networks/tertoos/releases/tag/v0.5.0
