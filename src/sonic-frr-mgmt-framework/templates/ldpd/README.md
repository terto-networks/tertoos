# LDP / L2VPN templates (TertoOS S7 + S11)

Este diretório hospedará os sub-templates Jinja2 que `frrcfgd` usará para
renderizar a configuração do FRR `ldpd` a partir das tabelas em CONFIG_DB
escritas pela CLI TertoOS:

- `MPLS_LDP_ROUTER` — instance global (router-id, holdtime, keepalive).
- `MPLS_LDP_AF` — per-AFI discovery (transport-address, targeted-hello).
- `MPLS_LDP_INTERFACE` — LDP-enabled interfaces.
- `MPLS_LDP_NEIGHBOR` — per-peer overrides (password, targeted, timers).
- `L2VPN_PW_CLASS` — pseudowire class (encapsulation, control-word, MTU).
- `L2VPN_XCONNECT_GROUP` — VPWS p2p attachments.

## Estado atual

**Skeleton** — apenas `ldpd.conf.j2` master existe como placeholder. Os
sub-templates `ldpd.conf.db.*.j2` ainda **não estão implementados**, e
`frrcfgd.py` registra as tabelas em `TABLE_DAEMON` mas **não tem handlers
nem key-maps** para dispatch.

## Por que skeleton

A entrega S7 + S11 cobre o **control-plane TertoOS** completo:
- KLISH IOS-XR (mpls ldp, l2vpn xconnect, pw-class, BGP vpnv4/vpnv6)
- YANG schema (`tertoos-mpls.yang`, `tertoos-l2vpn.yang`)
- translate.go → JSON Patch → CONFIG_DB

A renderização efetiva para FRR fica gated em SAI MPLS:
- AS5912 (Trident III): **não suporta MPLS pleno**
- Centec 7132 / 8180: plataforma alvo, ainda chegando ao lab

Render real será completado quando houver hardware Centec para validar
runtime end-to-end. Documentado em
[docs/sai-mpls-validation-plan.md](../../../terto-horizon/docs/sai-mpls-validation-plan.md)
e em [cli-gap-analysis.md](../../../terto-horizon/docs/cli-gap-analysis.md).

## TODO completar quando lab estiver pronto

1. `ldpd.conf.db.global.j2` — render `mpls ldp\n router-id ...\n holdtime ...`.
2. `ldpd.conf.db.af.j2` — render `address-family ipv4\n discovery transport-address ...`.
3. `ldpd.conf.db.interface.j2` — `interface <name>` blocks.
4. `ldpd.conf.db.neighbor.j2` — `neighbor <ip> password ...`.
5. `ldpd.conf.db.l2vpn.j2` — `l2vpn <group> type vpws\n bridge ...`.
6. Em `frrcfgd.py`:
   - Adicionar `mpls_ldp_global_key_map`, `mpls_ldp_af_key_map`,
     `mpls_ldp_interface_key_map`, `mpls_ldp_neighbor_key_map`,
     `l2vpn_pw_class_key_map`, `l2vpn_xconnect_key_map`.
   - Adicionar entries em `key_map_dict` e `subscribe list`.
   - Registrar handlers (reusar `bgp_table_handler_common`).
