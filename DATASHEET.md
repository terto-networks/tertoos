# TertoOS — Datasheet técnico

NOS de agregação ampla derivado do SONiC, com CLI 100% IOS-XR sobre
KLISH e ecossistema de gestão remota Horizon (agent + Edge + Core).
Posicionado para ISP de pequeno-médio porte e datacenters de
agregação.

**Status**: pre-release (v0.1 em bring-up). Lista abaixo cobre apenas
features que **estão implementadas e expostas via KLISH** no código.
Features planejadas/em desenvolvimento ficam na seção
[Roadmap](#roadmap), separadas.

---

## Sumário

1. [Posicionamento](#posicionamento)
2. [Hardware suportado](#hardware-suportado)
3. [Arquitetura CLI](#arquitetura-cli)
4. [Hierarquia de views](#hierarquia-de-views)
5. [Workflow two-stage commit](#workflow-two-stage-commit)
6. [Sistema e AAA](#sistema-e-aaa)
7. [Interfaces](#interfaces)
8. [VRF](#vrf)
9. [Routing IP unicast](#routing-ip-unicast)
10. [MPLS](#mpls)
11. [Segment Routing](#segment-routing)
12. [L2VPN](#l2vpn)
13. [EVPN](#evpn)
14. [QoS](#qos)
15. [ACL](#acl)
16. [Routing Policy (RPL)](#routing-policy-rpl)
17. [BFD](#bfd)
18. [Telemetria e gestão](#telemetria-e-gestão)
19. [Horizon agent](#horizon-agent)
20. [Image management (OTA local)](#image-management-ota-local)
21. [Show / Clear / Diagnóstico](#show--clear--diagnóstico)
22. [Limitações conhecidas](#limitações-conhecidas)
23. [Roadmap](#roadmap)

---

## Posicionamento

| | |
|---|---|
| **Use case alvo** | Agregação ampla — ISP pequeno/médio + DC de agregação |
| **Estilo de CLI** | IOS-XR 100% (commit-based, RPL, hierarquia em árvore) |
| **Base** | Fork de [SONiC](https://github.com/sonic-net/SONiC) com `sonic-mgmt-framework` patchado |
| **Linguagem do operador** | Português ou inglês (mensagens) — comandos em inglês |
| **Modelo de gestão** | CLI local (KLISH) **+** gestão remota via Horizon (agent NATS) |

---

## Hardware suportado

Build targets oficiais e estado de validação:

| Plataforma | Chipset | Build target | Validado |
|---|---|---|---|
| **Edgecore AS5912-54X-O** | Broadcom Trident III | `make PLATFORM=broadcom` | ✅ alvo de release v0.1 |
| **Centec V580-48X8 / 7132 (TsingMa)** | Centec TsingMa | `make PLATFORM=marvell-teralynx` | ⚠️ planejado v0.1 |
| **Centec V580-32X / 8180 (GoldenGate)** | Centec GoldenGate | `make PLATFORM=marvell-teralynx` | ⚠️ planejado v0.1 |
| **Virtual switch (qcow2/VM)** | Linux kernel software | `make PLATFORM=vs` | ⚠️ planejado v0.2 |
| Outros (Mellanox, Marvell, Arista) | Vários | Heredados do upstream | ❌ não validados pelo TertoOS |

Hardware decision: Trident III para non-MPLS (BGP/EVPN-VXLAN/L3VPN); Centec
para MPLS de produção (SR-MPLS, MPLS-TE, hardware acceleration).

---

## Arquitetura CLI

### Glossário

- **KLISH**: shell embedded (versão 2.1.4 no fork), interpretador de XML
  que define hierarquia de comandos, validação por regex (PTYPE), e
  ações (geralmente Python ou shell).
- **CONFIG_DB**: banco Redis (DB 4) onde live a configuração corrente
  do switch. Daemons consomem e programam o ASIC via SAI.
- **Candidate datastore**: cópia da config onde mudanças ficam
  pendentes. `commit` aplica atomicamente; `abort` descarta.
- **GCU (Generic Config Updater)**: módulo do SONiC que aplica diff
  do candidate ao CONFIG_DB.
- **RPL (Routing Policy Language)**: linguagem IOS-XR para policy de
  roteamento. Substitui route-maps. Compilada para FRR internamente.
- **PTYPE**: tipo paramétrico KLISH (regex de validação) — ex: `PTYPE_ASN`,
  `PTYPE_IPV4`, `PTYPE_NET`, `PTYPE_LABEL`. Centralizados em `00-types.xml`.

### Princípios

1. **Two-stage commit obrigatório**. Toda mutação em `config-view`
   escreve no candidate; nunca direto no CONFIG_DB.
2. **Hierarquia em árvore** (não comandos planos). `show configuration`
   renderiza a árvore — não a sequência de comandos digitados.
3. **RPL única forma de policy**. Sem route-map. Tradutor compila
   RPL → estrutura FRR.
4. **`Bundle-Ether` substitui `PortChannel`** na superfície externa
   (YANG interno reusa sonic-portchannel).
5. **PTYPEs centralizados** em `00-types.xml` — regex nunca duplicado.

---

## Hierarquia de views

```
exec-view              tertoos>             ← user comum (read-only operacional)
└── enable             tertoos#             ← privileged (após `enable`)
    privileged-view
    ├── show ...                            ← runtime/operational state
    ├── clear ...                           ← reset de counters/sessões
    ├── reload                              ← reboot
    ├── ping / traceroute / ssh
    ├── image install/activate/commit/...   ← OTA local (S13.D.1)
    └── configure terminal
        config-view    tertoos(config)#     ← candidate datastore
        ├── commit [confirmed [<min>]] [label <l>] [comment <c>]
        ├── abort
        ├── rollback configuration {last <n>|to <label>}
        ├── show configuration {merge|running|failed|commit changes}
        ├── hostname <name>
        ├── banner motd|login|exec
        ├── interface <name>          → config-if-view
        ├── vrf <name>                → config-vrf-view
        ├── router bgp <asn>          → config-bgp-view
        ├── router ospf <id>          → config-ospf-view
        ├── router ospfv3 <id>        → config-ospfv3-view
        ├── router isis <tag>         → config-isis-view
        ├── mpls ldp                  → config-ldp-view
        ├── segment-routing           → config-sr-view
        ├── l2vpn xconnect group <n>  → config-l2vpn-xconn-view
        ├── l2vpn bridge-domain <n>   → config-l2vpn-bd-view
        ├── l2vpn vfi <n>             → config-l2vpn-vfi-view
        ├── evpn                      → config-evpn-view
        ├── ipv4 access-list <n>      → config-ipv4-acl
        ├── ipv6 access-list <n>      → config-ipv6-acl
        ├── ethernet-services access-list <n> → config-l2-acl
        ├── prefix-set <n>            → config-prefix-set
        ├── community-set <n>         → config-community-set
        ├── route-policy <n>          → config-rpl
        ├── class-map <n>             → config-classmap
        ├── policy-map <n>            → config-policymap
        ├── policer <n>               → config-policer
        ├── line ...                  → config-line-view
        ├── username / aaa / tacacs / radius / snmp-server
        ├── ntp / logging / lldp / sflow / ssh / grpc
        ├── horizon ...               ← Horizon agent (S13)
        └── bfd                       → config-bfd-view
```

---

## Workflow two-stage commit

### Mutação típica

```
tertoos# configure terminal
tertoos(config)# interface Ethernet0
tertoos(config-if)# description Uplink to PE2
tertoos(config-if)# ipv4 address 10.0.0.1/30
tertoos(config-if)# no shutdown
tertoos(config-if)# exit
tertoos(config)# show configuration         ← preview do candidate
tertoos(config)# commit                     ← aplica atomicamente
% Commit a1b2c3 succeeded
tertoos(config)# end
tertoos#
```

### Commit confirmed (rollback automático se não confirmar)

```
tertoos(config)# commit confirmed 5         ← confirma em 5min ou rollback
tertoos(config)# end
tertoos# ... (testa conectividade) ...
tertoos# configure terminal
tertoos(config)# commit                     ← confirma definitivamente
```

Se você sair sem `commit` em 5min, o sistema rola back automaticamente.
Salva-vidas para mudanças em management network.

### Rollback explícito

```
tertoos# configure terminal
tertoos(config)# rollback configuration last 1     ← desfaz último commit
tertoos(config)# rollback configuration to v1.0    ← rollback para label
```

### Labels e comentários

```
tertoos(config)# commit label maintenance-window-1 comment "Adding 5 new uplinks"
```

`label` permite rollback explícito por nome; `comment` aparece em
`show configuration commit changes`.

---

## Sistema e AAA

### Hostname e banners

```
tertoos(config)# hostname pe1.sp.tertonet.io
tertoos(config)# banner motd "Authorized access only"
tertoos(config)# banner login "Login required"
tertoos(config)# banner exec "Welcome to TertoOS"
tertoos(config)# no banner motd                  ← clear
```

### AAA local

```
tertoos(config)# username netops group admin password CHANGE-ME
tertoos(config)# username monitor group read-only password ...
tertoos(config)# no username old-user
```

Grupos disponíveis: `admin | operator | netadmin | secadmin | read-only`.

### TACACS+

```
tertoos(config)# tacacs-server timeout 5
tertoos(config)# tacacs-server auth-type pap
tertoos(config)# tacacs-server key SECRET
tertoos(config)# tacacs-server host 10.0.0.5 key per-server-secret
tertoos(config)# no tacacs-server host 10.0.0.5
```

### RADIUS

```
tertoos(config)# radius-server timeout 5
tertoos(config)# radius-server retransmit 3
tertoos(config)# radius-server key SECRET
tertoos(config)# radius-server host 10.0.0.6 key per-server-secret
```

### Login policy

```
tertoos(config)# aaa authentication login default local,tacacs+
tertoos(config)# no aaa authentication login default       ← reset
```

### Line config (console / vty)

```
tertoos(config)# line default
tertoos(config-line)# exec-timeout 10
tertoos(config-line)# transport ssh
tertoos(config-line)# access-class my-mgmt-acl ingress
tertoos(config-line)# baud-rate 115200       ← console only
tertoos(config-line)# login local

tertoos(config)# line template restricted    ← named template
```

### NTP

```
tertoos(config)# ntp server 200.160.0.8 iburst
tertoos(config)# ntp server pool.ntp.br prefer
tertoos(config)# ntp server 10.0.0.1 version 4
tertoos(config)# ntp server 10.0.0.1 key 1
tertoos(config)# ntp authentication-key 1 md5 SECRET
tertoos(config)# ntp trusted-key 1
tertoos(config)# ntp authenticate
tertoos(config)# ntp source Loopback0
tertoos(config)# ntp vrf mgmt
```

### Logging (syslog remoto)

```
tertoos(config)# logging 10.0.0.10
tertoos(config)# logging 10.0.0.10 port 514 protocol udp severity info
tertoos(config)# logging 10.0.0.10 vrf mgmt
tertoos(config)# logging trap warning
tertoos(config)# logging source-interface Loopback0
tertoos(config)# no logging 10.0.0.10
```

Severities: `emerg|alert|crit|error|warning|notice|info|debug`.

### SNMP

```
tertoos(config)# snmp-server contact "noc@example.com"
tertoos(config)# snmp-server location "Sao Paulo - DC1"
tertoos(config)# snmp-server community public ro
tertoos(config)# snmp-server community private rw
tertoos(config)# snmp-server user opsmon auth-sha
tertoos(config)# snmp-server agent-address 10.0.0.1 port 161 vrf mgmt
```

### SSH server

```
tertoos(config)# ssh server v2
tertoos(config)# ssh server port 22
tertoos(config)# ssh server vrf mgmt
```

### sFlow

```
tertoos(config)# sflow enable
tertoos(config)# sflow agent-id Loopback0
tertoos(config)# sflow polling-interval 30
tertoos(config)# sflow sample-direction both
tertoos(config)# sflow collector colA 10.0.0.20 6343
tertoos(config)# sflow collector colA vrf mgmt
```

### LLDP

```
tertoos(config)# lldp run
tertoos(config)# lldp hello 30
tertoos(config)# lldp multiplier 4
tertoos(config)# lldp system-name pe1.tertonet
tertoos(config)# lldp system-description "TertoOS 0.1"
tertoos(config)# lldp tlv-select mgmt-address
```

### gNMI / gRPC telemetry server

```
tertoos(config)# grpc server enable
tertoos(config)# grpc server port 9339
tertoos(config)# grpc server log-level 3
tertoos(config)# grpc server client-auth cert
tertoos(config)# grpc server certificate /etc/sonic/ca.pem /etc/sonic/server.crt /etc/sonic/server.key
```

---

## Interfaces

### Tipos suportados

- `EthernetN` — porta física.
- `Bundle-EtherN` — agregação LACP (alias `BEN`).
- `<interface>.<vlan>` — sub-interface dot1q.
- `Loopback<N>` — loopback.
- `Mgmt<N>` — porta de management (eth0).

### Comandos comuns (`config-if-view`)

```
tertoos(config)# interface Ethernet0
tertoos(config-if)# description Uplink to spine-1
tertoos(config-if)# mtu 9100
tertoos(config-if)# no shutdown
tertoos(config-if)# load-interval 30
tertoos(config-if)# ipv4 address 10.0.0.1/30
tertoos(config-if)# ipv6 address 2001:db8::1/127
tertoos(config-if)# vrf customer-A
tertoos(config-if)# encapsulation dot1q vlan-id 100      ← em sub-if
tertoos(config-if)# bundle id 1 mode active              ← LACP member
```

### ACL bind

```
tertoos(config-if)# ipv4 access-group permit-mgmt ingress
tertoos(config-if)# ipv6 access-group permit-v6 egress
tertoos(config-if)# ethernet-services access-group L2-policy ingress
tertoos(config-if)# no ipv4 access-group permit-mgmt
```

### Bundle-Ether (LACP)

Aceita `Bundle-Ether 1` ou `BE1`. Internamente vira PortChannel.

```
tertoos(config)# interface Ethernet0
tertoos(config-if)# bundle id 1 mode active

tertoos(config)# interface Ethernet1
tertoos(config-if)# bundle id 1 mode active

tertoos(config)# interface Bundle-Ether1
tertoos(config-if)# ipv4 address 10.1.0.1/30
```

### Sub-interfaces dot1q

```
tertoos(config)# interface Ethernet5.100
tertoos(config-if)# encapsulation dot1q vlan-id 100
tertoos(config-if)# ipv4 address 192.168.100.1/24
```

---

## VRF

```
tertoos(config)# vrf customer-A
tertoos(config-vrf)# rd 65000:100
tertoos(config-vrf)# vni 10100                ← L3 VNI para EVPN Type-5
tertoos(config-vrf)# address-family ipv4 unicast
tertoos(config-vrf-af)# rt import 65000:100
tertoos(config-vrf-af)# rt export 65000:100
tertoos(config-vrf-af)# rt import rpl my-import-policy   ← RT controlado por RPL
tertoos(config-vrf-af)# exit
tertoos(config-vrf)# address-family ipv6 unicast
tertoos(config-vrf-af)# rt import 65000:100
tertoos(config-vrf-af)# rt export 65000:100
```

---

## Routing IP unicast

### OSPFv2

```
tertoos(config)# router ospf 1
tertoos(config-ospf)# router-id 1.1.1.1
tertoos(config-ospf)# log-adjacency-changes detail
tertoos(config-ospf)# auto-cost reference-bandwidth 100000
tertoos(config-ospf)# default-metric 100
tertoos(config-ospf)# distance ospf intra-area 110
tertoos(config-ospf)# passive-interface default
tertoos(config-ospf)# no passive-interface Ethernet0
tertoos(config-ospf)# segment-routing
tertoos(config-ospf)# segment-routing global-block 16000 23999
tertoos(config-ospf)# segment-routing local-block 15000 15999
tertoos(config-ospf)# segment-routing prefix-sid-map 10.0.0.1/32 100

# Per-VRF
tertoos(config)# router ospf 2 vrf customer-A
```

### Por interface (em config-if):

```
tertoos(config-if)# ip ospf area 1 0
tertoos(config-if)# ip ospf cost 100
tertoos(config-if)# ip ospf hello-interval 10
tertoos(config-if)# ip ospf dead-interval 40
tertoos(config-if)# ip ospf network point-to-point
```

### OSPFv3

```
tertoos(config)# router ospfv3 1
tertoos(config-ospfv3)# router-id 1.1.1.1
tertoos(config-ospfv3)# segment-routing
tertoos(config-ospfv3)# segment-routing global-block 16000 23999
tertoos(config-ospfv3)# segment-routing prefix-sid-map 2001:db8::1/128 100
tertoos(config-ospfv3)# passive-interface default
```

### IS-IS

```
tertoos(config)# router isis CORE
tertoos(config-isis)# net 49.0001.0192.0168.0001.00
tertoos(config-isis)# is-type level-2-only
tertoos(config-isis)# metric-style wide
tertoos(config-isis)# dynamic-hostname
tertoos(config-isis)# lsp-lifetime 1200
tertoos(config-isis)# lsp-refresh-interval 900
tertoos(config-isis)# area-password SECRET
tertoos(config-isis)# domain-password SECRET
tertoos(config-isis)# segment-routing on
```

### BGP

```
tertoos(config)# router bgp 65000
tertoos(config-bgp)# bgp router-id 1.1.1.1
tertoos(config-bgp)# bgp cluster-id 1.1.1.1                ← RR
tertoos(config-bgp)# bgp graceful-restart
tertoos(config-bgp)# bgp log-neighbor-changes
tertoos(config-bgp)# bgp always-compare-med
tertoos(config-bgp)# timers bgp 30 90
```

#### Address families

```
tertoos(config-bgp)# address-family ipv4 unicast
tertoos(config-bgp-af)# exit
tertoos(config-bgp)# address-family ipv6 unicast
tertoos(config-bgp)# address-family vpnv4 unicast          ← L3VPN
tertoos(config-bgp)# address-family vpnv6 unicast
tertoos(config-bgp)# address-family l2vpn evpn             ← EVPN
tertoos(config-bgp-af)# advertise-all-vni
tertoos(config-bgp-af)# advertise ipv4 unicast             ← Type-5
tertoos(config-bgp-af)# advertise ipv6 unicast
tertoos(config-bgp-af)# encapsulation vxlan
```

#### Session-groups e af-groups (templates)

```
tertoos(config-bgp)# session-group RR-CORE
tertoos(config-bgp-sg)# remote-as 65000
tertoos(config-bgp-sg)# update-source Loopback0

tertoos(config-bgp)# af-group VPNV4-RR address-family vpnv4 unicast
tertoos(config-bgp-afg)# route-reflector-client

tertoos(config-bgp)# neighbor 10.0.0.2
tertoos(config-bgp-nb)# use session-group RR-CORE
tertoos(config-bgp-nb)# use af-group VPNV4-RR address-family vpnv4 unicast
```

#### VRF

```
tertoos(config)# router bgp 65000 vrf customer-A
tertoos(config-bgp)# address-family ipv4 unicast
tertoos(config-bgp-af)# redistribute connected
tertoos(config-bgp-af)# redistribute static
```

---

## MPLS

### LDP

```
tertoos(config)# mpls ldp
tertoos(config-ldp)# router-id 1.1.1.1
tertoos(config-ldp)# holdtime 180
tertoos(config-ldp)# keepalive 60
tertoos(config-ldp)# discovery hello holdtime 15
tertoos(config-ldp)# discovery hello interval 5
tertoos(config-ldp)# graceful-restart
tertoos(config-ldp)# graceful-restart helper
tertoos(config-ldp)# graceful-restart reconnect-time 120
tertoos(config-ldp)# graceful-restart recovery-time 240

tertoos(config-ldp)# address-family ipv4
tertoos(config-ldp-af)# discovery transport-address 1.1.1.1
tertoos(config-ldp-af)# discovery targeted-hello accept
tertoos(config-ldp-af)# label local allocate host-routes
tertoos(config-ldp-af)# interface Ethernet0
tertoos(config-ldp-af)# interface Ethernet1

tertoos(config-ldp)# neighbor 2.2.2.2
tertoos(config-ldp-nb)# password MD5-SECRET
```

LDP per-VRF: `mpls ldp vrf <name>`.

---

## Segment Routing

SR-MPLS via OSPF/ISIS (control plane), SR-TE policy via PCEP ou BGP-LU.

### SR-TE policy

```
tertoos(config)# segment-routing
tertoos(config-sr)# policy 10.10.10.10 color 100
tertoos(config-sr-policy)# segment-list LIST-A
tertoos(config-sr-policy-sl)# index 10 mpls label 16001
tertoos(config-sr-policy-sl)# index 20 mpls label 16002
tertoos(config-sr-policy-sl)# index 30 mpls label 16003
```

### Verificação

```
tertoos# show sr-te policy
tertoos# show sr-te policy endpoint 10.10.10.10
tertoos# show sr-te pcep
tertoos# show segment-routing prefix-sid
tertoos# show mpls table                         ← LFIB do zebra
tertoos# clear sr-te policy endpoint 10.10.10.10
```

---

## L2VPN

Implementação cobre **VPWS (xconnect point-to-point)** e **VPLS via
bridge-domain + VFI**.

### Pseudowire class

```
tertoos(config)# pw-class metro-pw
tertoos(config-pw)# encapsulation mpls
tertoos(config-pw)# control-word
tertoos(config-pw)# transport-mode vlan         ← ou ethernet
```

### VPWS xconnect (point-to-point)

```
tertoos(config)# l2vpn xconnect group ISP-DC1
tertoos(config-l2vpn-xconn)# p2p customer-100
tertoos(config-l2vpn-p2p)# interface Ethernet5.100
tertoos(config-l2vpn-p2p)# neighbor 2.2.2.2 pw-id 100 pw-class metro-pw
```

### VPLS — bridge-domain + VFI

```
tertoos(config)# l2vpn vfi metro-vfi
tertoos(config-l2vpn-vfi)# vpn-id 100
tertoos(config-l2vpn-vfi)# neighbor 2.2.2.2 pw-id 100
tertoos(config-l2vpn-vfi)# neighbor 3.3.3.3 pw-id 100

tertoos(config)# l2vpn bridge-domain bd-100
tertoos(config-l2vpn-bd)# description Metro broadcast domain
tertoos(config-l2vpn-bd)# mac aging 300
tertoos(config-l2vpn-bd)# mac limit 4096
tertoos(config-l2vpn-bd)# flooding unknown-unicast enable
tertoos(config-l2vpn-bd)# flooding broadcast enable
tertoos(config-l2vpn-bd)# vfi metro-vfi
tertoos(config-l2vpn-bd)# interface Ethernet5.100
```

### Show

```
tertoos# show l2vpn xconnect
tertoos# show l2vpn bridge-domain
tertoos# show l2vpn vfi
tertoos# show mpls l2transport vc
```

---

## EVPN

EVPN multi-encapsulation: VXLAN (data center) ou MPLS (provider).

### VXLAN VTEP setup

```
tertoos(config)# evpn
tertoos(config-evpn)# vxlan source-interface Loopback0
tertoos(config-evpn)# vxlan vlan 100 vni 10100
tertoos(config-evpn)# nvo source-interface Loopback0
```

### EVI (EVPN instance)

```
tertoos(config-evpn)# evi 100
tertoos(config-evpn-evi)# vni 10100
tertoos(config-evpn-evi)# route-target import 65000:100
tertoos(config-evpn-evi)# route-target export 65000:100
```

### Ethernet-segment (multi-homing)

```
tertoos(config-evpn)# ethernet-segment ES-A
tertoos(config-evpn-es)# interface Bundle-Ether1
tertoos(config-evpn-es)# identifier type-0 00:11:22:33:44:55:66:77:88
tertoos(config-evpn-es)# load-balancing mode all-active
tertoos(config-evpn-es)# df-election method preference
tertoos(config-evpn-es)# df-election preference 100
```

### Show e clear

```
tertoos# show evpn vni
tertoos# show evpn encapsulation
tertoos# clear evpn dup-addr
tertoos# clear bgp l2vpn evpn
```

---

## QoS

QoS é amplo: maps DSCP/TC/queue/PG, schedulers, WRED, buffer pools/profiles,
class-map, policy-map, policer.

### Mapas

```
tertoos(config)# qos map dscp-to-tc DEFAULT-DSCP-TC
tertoos(config-qos-map)# entry 0..7 traffic-class 0
tertoos(config-qos-map)# entry 46 traffic-class 5

tertoos(config)# qos map tc-to-queue DEFAULT-TC-Q
tertoos(config)# qos map tc-to-pg DEFAULT-TC-PG
```

### Scheduler

```
tertoos(config)# qos scheduler EXPEDITED
tertoos(config-sched)# type strict
tertoos(config-sched)# weight 0
tertoos(config-sched)# meter-type bytes
tertoos(config-sched)# cir 100000000
tertoos(config-sched)# pir 200000000
```

### WRED profile

```
tertoos(config)# wred-profile WRED-A
tertoos(config-wred)# ecn ecn_green_yellow
tertoos(config-wred)# green min-threshold 100000 max-threshold 1000000 drop-prob 1
tertoos(config-wred)# yellow min-threshold 50000 max-threshold 500000 drop-prob 5
tertoos(config-wred)# red min-threshold 10000 max-threshold 100000 drop-prob 10
```

### Buffer pool / profile

```
tertoos(config)# buffer-pool ingress-pool
tertoos(config-bpool)# size 12000000

tertoos(config)# buffer-profile pg-7-profile
tertoos(config-bprof)# pool ingress-pool
tertoos(config-bprof)# size 1518
tertoos(config-bprof)# dynamic-th 0
```

### class-map

```
tertoos(config)# class-map type qos match-any VOIP
tertoos(config-cmap)# match dscp 46
tertoos(config-cmap)# match cos 5
tertoos(config-cmap)# match traffic-class 5
tertoos(config-cmap)# match access-group ipv4 voip-acl
```

### policy-map

```
tertoos(config)# policy-map type qos MARK-VOIP
tertoos(config-pmap)# class VOIP
tertoos(config-pmap-c)# set traffic-class 5
tertoos(config-pmap-c)# set dscp 46
tertoos(config-pmap-c)# police rate-limit-voip
tertoos(config-pmap-c)# queue 5
tertoos(config-pmap-c)# wred-profile WRED-A
```

### policer

```
tertoos(config)# policer rate-limit-voip
tertoos(config-policer)# mode sr_tcm
tertoos(config-policer)# meter-type bytes
tertoos(config-policer)# color blind
tertoos(config-policer)# cir 10000000
tertoos(config-policer)# cbs 100000
tertoos(config-policer)# green-action forward
tertoos(config-policer)# yellow-action forward
tertoos(config-policer)# red-action drop
```

### Aplicar à interface

```
tertoos(config)# interface Ethernet0
tertoos(config-if)# service-policy input MARK-VOIP
tertoos(config-if)# service-policy output OUTPUT-SHAPER
```

---

## ACL

Tipos: IPv4, IPv6, L2 (ethernet-services).

```
tertoos(config)# ipv4 access-list permit-mgmt
tertoos(config-ipv4-acl)# description "Allow management traffic"
tertoos(config-ipv4-acl)# permit 10 ip 10.0.0.0/8 any
tertoos(config-ipv4-acl)# permit 20 tcp any any
tertoos(config-ipv4-acl)# deny 30 ip any any
tertoos(config-ipv4-acl)# remark 25 "Block specific port"
tertoos(config-ipv4-acl)# no 30                              ← remove

tertoos(config)# ipv6 access-list permit-v6
tertoos(config-ipv6-acl)# permit 10 ipv6 2001:db8::/32 any

tertoos(config)# ethernet-services access-list L2-A
tertoos(config-l2-acl)# permit 10 ...
```

---

## Routing Policy (RPL)

Conjuntos nomeados + policies condicionais — substitui route-map.

### Sets

```
tertoos(config)# prefix-set CUST-A-NETS
tertoos(config-prefix-set)# permit 10 ipv4 10.0.0.0/8 le 24
tertoos(config-prefix-set)# permit 20 ipv6 2001:db8::/32 ge 48 le 64

tertoos(config)# community-set NO-EXPORT
tertoos(config-community-set)# match-action all
tertoos(config-community-set)# member 65000:100
tertoos(config-community-set)# member no-export

tertoos(config)# extcommunity-set rt CUST-A-RT
tertoos(config-extcomm-set)# member 65000:100

tertoos(config)# as-path-set TIER1
tertoos(config-as-path-set)# member ^174_       ← regex
```

### Route-policy

```
tertoos(config)# route-policy import-cust-A
tertoos(config-rpl)# if destination in CUST-A-NETS then
tertoos(config-rpl-block)#   set local-preference 200
tertoos(config-rpl-block)#   set community NO-EXPORT additive
tertoos(config-rpl-block)# elseif as-path passes-through TIER1 then
tertoos(config-rpl-block)#   drop
tertoos(config-rpl-block)# endif
tertoos(config-rpl)# end-policy
```

### Aplicar

```
tertoos(config)# router bgp 65000
tertoos(config-bgp)# neighbor 1.1.1.1
tertoos(config-bgp-nb)# address-family ipv4 unicast
tertoos(config-bgp-nb-af)# route-policy import-cust-A in
tertoos(config-bgp-nb-af)# route-policy export-cust-A out
```

---

## BFD

```
tertoos(config)# bfd

tertoos(config-bfd)# singlehop peer 10.0.0.2 interface Ethernet0
tertoos(config-bfd-peer)# interval min-tx 100 min-rx 100
tertoos(config-bfd-peer)# detect-multiplier 3
tertoos(config-bfd-peer)# echo enable
tertoos(config-bfd-peer)# passive
tertoos(config-bfd-peer)# no shutdown

tertoos(config-bfd)# multihop peer 2.2.2.2 local-address 1.1.1.1 vrf default
tertoos(config-bfd-peer)# interval min-tx 200 min-rx 200
tertoos(config-bfd-peer)# detect-multiplier 5

tertoos(config-bfd)# no singlehop peer 10.0.0.2
```

---

## Telemetria e gestão

### gNMI / gRPC server

(Já listado em [Sistema](#sistema-e-aaa).)

### Aplicar gNMI a uma sessão pull/subscribe

Depende do cliente externo (`gnmic`, `gnmi_cli`). TertoOS expõe o
servidor; cliente fica fora do escopo do datasheet.

---

## Horizon agent

Agent NOS-side que se conecta ao Edge local via NATS para gestão
remota (config push, telemetria, OTA, revogação de cert).

```
tertoos(config)# horizon enable
tertoos(config)# horizon disable                   ← alias para `no horizon enable`

tertoos(config)# horizon tenant-id <UUID>          ← assigned by Core
tertoos(config)# horizon site-id <slug>            ← Edge local
tertoos(config)# horizon broker nats://edge.local:4222
tertoos(config)# horizon enrollment-token <token>  ← write-once
tertoos(config)# no horizon enrollment-token       ← clear

tertoos(config)# horizon interval-heartbeat 30     ← seconds
tertoos(config)# horizon interval-counters 10
tertoos(config)# horizon subject-prefix horizon
```

### Verificação operacional

```
tertoos# show horizon                 ← agent state, broker URL, enrolled?
tertoos# show horizon telemetry       ← último heartbeat publicado
tertoos# show horizon queue           ← messages pendentes
```

Detalhe completo do pipeline em
[`src/terto-horizon/docs/AGENT.md`](src/terto-horizon/docs/AGENT.md).

---

## Image management (OTA local)

Comando `image` em privileged-view (não config), faz wrapping de
`sonic-installer` + verificação de assinatura ECDSA-P256+SHA-256
(detached `.bin.sig`).

```
tertoos# image install https://distrib.example.com/tos-1.0.bin
tertoos# image install https://...   no-verify        ← skip signature
tertoos# image activate next                          ← marca next-boot
tertoos# image activate slot1                         ← slot específico
tertoos# image commit                                 ← confirma slot atual
tertoos# image rollback                               ← reverte slot
tertoos# image list                                   ← installed images
tertoos# image verify /tmp/tos-1.0.bin                ← verifica assinatura
```

Cert de signing fica em `/etc/tertoos/ota/signing-cert.pem`. Bundle
spec + signing workflow operator-side em
[`src/terto-horizon/docs/OTA.md`](src/terto-horizon/docs/OTA.md).

OTA via Horizon (push-based, da Core) é S13.D.2 — agent automaticamente
chama esses mesmos comandos quando recebe `ota.install` no NATS.

---

## Show / Clear / Diagnóstico

### Geral

```
tertoos# show version
tertoos# show clock
tertoos# show interfaces
tertoos# show ipv4 interface brief
tertoos# show ipv4 route
```

### BGP

```
tertoos# show bgp summary
tertoos# show bgp summary vrf customer-A
tertoos# show bgp neighbors
tertoos# show bgp neighbor 1.1.1.1
tertoos# show bgp ipv4 unicast
tertoos# show bgp ipv4 unicast prefix 10.0.0.0/24
tertoos# show bgp ipv6 unicast
tertoos# show bgp ipv6 unicast prefix 2001:db8::/32
tertoos# show bgp vpnv4 unicast
tertoos# show bgp vpnv4 unicast vrf customer-A
tertoos# show bgp vpnv6 unicast
tertoos# show bgp l2vpn evpn                      ← (via show bgp ...)
```

### OSPF / OSPFv3 / IS-IS

```
tertoos# show ospf
tertoos# show ospf vrf customer-A
tertoos# show ospf neighbor
tertoos# show ospf interface
tertoos# show ospf database
tertoos# show ipv6 ospf
tertoos# show isis summary
tertoos# show isis neighbor
tertoos# show isis database
```

### MPLS

```
tertoos# show mpls ldp neighbor
tertoos# show mpls ldp binding
tertoos# show mpls ldp interface
tertoos# show mpls ldp discovery
tertoos# show mpls table
```

### Segment Routing

```
tertoos# show segment-routing prefix-sid
tertoos# show sr-te policy
tertoos# show sr-te policy endpoint 10.0.0.1
tertoos# show sr-te pcep
```

### L2VPN

```
tertoos# show l2vpn xconnect
tertoos# show l2vpn bridge-domain
tertoos# show l2vpn vfi
tertoos# show mpls l2transport vc
```

### EVPN

```
tertoos# show evpn vni
tertoos# show evpn encapsulation
```

### BFD

```
tertoos# show bfd peers
tertoos# show bfd peers detail
```

### Clear

```
tertoos# clear counters
tertoos# clear bgp                                ← all sessions
tertoos# clear bgp neighbor 1.1.1.1
tertoos# clear bgp neighbor 1.1.1.1 soft
tertoos# clear bgp vrf customer-A
tertoos# clear ip ospf process
tertoos# clear ipv6 ospf process
tertoos# clear isis
tertoos# clear isis vrf customer-A
tertoos# clear mpls ldp neighbor
tertoos# clear mpls ldp neighbor peer 2.2.2.2
tertoos# clear evpn dup-addr
tertoos# clear bgp l2vpn evpn
tertoos# clear bfd statistics
tertoos# clear sr-te policy endpoint 10.0.0.1
```

### Reload

```
tertoos# reload
tertoos# reload location 0/0/0                    ← line card específica (chassis)
tertoos# reload warm                              ← warm reboot
```

### Diagnóstico de rede

```
tertoos# ping 1.1.1.1
tertoos# ping 1.1.1.1 vrf customer-A
tertoos# traceroute 1.1.1.1
tertoos# ssh 10.0.0.2
tertoos# ssh 10.0.0.2 vrf mgmt
```

### Configuration audit

```
tertoos(config)# show configuration                 ← candidate (não-aplicado)
tertoos(config)# show configuration merge           ← candidate + running
tertoos(config)# show configuration running         ← apenas running
tertoos(config)# show configuration failed          ← último commit que falhou
tertoos(config)# show configuration commit changes  ← histórico de commits
```

---

## Limitações conhecidas

Honestidade sobre o que **não** está expostos via KLISH (mesmo que
exista no kernel/SONiC/FRR underneath):

### Não exposto na CLI ainda

- ❌ **MPLS-TE** (RSVP-TE bandwidth reservation): FRR backend tem; XML
  KLISH não tem comandos. Use FRR vtysh manualmente como workaround.
- ❌ **Multicast** (PIM, IGMP, MLD): não exposto. Snooping incluído em S15.I (deferido).
- ❌ **DHCP server / relay**: não exposto via TertoOS KLISH (fica no
  KLISH SONiC clássico — incompatível com IOS-XR look).
- ❌ **VRRP**: não exposto.
- ❌ **GRE / IP tunnels**: não exposto.
- ❌ **NAT** (estado-NAT, source-NAT): não exposto.
- ❌ **Firewall stateful** (ZBFW): não exposto.
- ❌ **MAC ACL** beyond ethernet-services basics.

### S15 — L2 CLI overlay (entregue)

Features expostas em S15 (sprint pós-bring-up):

- ✅ **Spanning Tree** (PVST/RSTP/MST): mode, timers (forward-time, hello-time, max-age), priority, per-VLAN bridge_priority, root primary/secondary syntactic sugar, MST configuration (name, revision, instance, max-hops), per-port portfast, bpdu-guard, root-guard, uplink-fast, edge-port, per-VLAN-per-port cost/priority. Show: `show spanning-tree [summary|vlan|interface|mst|root|blocked|counters]`. Clear: counters + detected-protocols.
- ✅ **Storm-control** per-port: broadcast/multicast/unknown-unicast em kbps ou pps. Show: `show storm-control [interface]`.
- ✅ **MAC address-table**: aging-time global, static entries, show por VLAN/interface/MAC/dynamic/static/count, clear dynamic por VLAN/interface/address.
- ✅ **VLAN aggregator**: `show vlan [brief|id|summary]` enumera VLANs em uso (sub-interfaces, bridge-domains, EVPN VLAN-VNI, Q-in-Q outer).
- ✅ **Q-in-Q sub-interface**: `encapsulation dot1q <s> second-dot1q <c|any>` para stack de tags na sub-if.
- ✅ **Encapsulation untagged**: `encapsulation untagged` em config-if (l2transport).
- ✅ **interface l2transport**: marca porta como L2-puro (sem L3 processing).
- ✅ **Per-port MAC learning**: `mac-learning enable|disable`.
- ✅ **Per-port MAC limit**: `mac-limit <n>`, `mac-limit action drop|shutdown|log`.

### Limitações em VS (simulador)

Em build `PLATFORM=vs`:
- ❌ Hardware monitoring (`show platform fan/psu/temp`): VS não tem sensores.
- ❌ Transceiver detection: VS não tem SFP+.
- ⚠️ MPLS dataplane: parcial via Linux `mpls_router`. Sem TE.
- ⚠️ ASIC ACL TCAM: limitado pelo iptables (escala menor).
- ❌ Line-rate forwarding: software dataplane ~1-10 Gbps por core.

### Limitações em Trident III (AS5912)

- ⚠️ **MPLS HW programming**: Trident III tem suporte limitado de label
  stack depth e label types. SR-MPLS dataplane funciona; TE limitado.
- ❌ **EVPN-MPLS dataplane**: Trident III prefere VXLAN. Use Centec para
  EVPN-MPLS de produção.

---

## Roadmap

Itens conhecidos não-implementados, em ordem de prioridade:

| # | Feature | Sprint | Status |
|---|---|---|---|
| 1 | **MPLS-TE** (RSVP-TE) via KLISH | S15 | planejado |
| 2 | **PIM-SM/SSM + IGMP** | S16 | planejado |
| 3 | **VRRPv2/v3** | S16 | planejado |
| 4 | **DHCP relay** | S17 | planejado |
| 5 | **VS image distribuição pública** (qcow2 EVE-NG/GNS3) | S13.D.4+ | roadmap em `terto-horizon/docs/POPULARIZATION-ROADMAP.md` |
| 6 | **Edge appliance + Core-lite** | S13.F+G | roadmap em popularization |
| 7 | **NAT** (S-NAT, D-NAT) | S18 | planejado |
| 8 | **NETCONF server** (paralelo a gNMI) | S19 | planejado |

Detalhes do estado de cada sprint S13.X em
[`src/terto-horizon/docs/cli-gap-analysis.md`](src/terto-horizon/docs/cli-gap-analysis.md).

---

## Referências internas

- [`build-machine/`](build-machine/) — setup do servidor de build, CI pipeline, security
- [`src/terto-horizon/`](src/terto-horizon/) — agent + Edge + Core (multi-repo)
  - `docs/CRL.md` — cert lifecycle e revogação
  - `docs/CONFIG-PIPELINE.md` — config descending pipeline
  - `docs/OTA-PIPELINE.md` — OTA push end-to-end
  - `docs/cli-gap-analysis.md` — estado por feature, sprint-by-sprint
- [`src/sonic-mgmt-framework/CLI/clitree/cli-xml/tertoos/`](src/sonic-mgmt-framework/CLI/clitree/cli-xml/tertoos/) — XMLs KLISH do fork
- README.md — overview do repo

---

**Versão deste datasheet**: gerado com base na branch `master` de
`terto-networks/tertoos`. Comandos confirmados via grep dos XMLs
KLISH em `cli-xml/tertoos/` e privileged-view. Atualizar a cada
mudança em `cli-xml/tertoos/*.xml`.
