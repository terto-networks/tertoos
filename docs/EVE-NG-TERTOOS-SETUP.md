# EVE-NG — instalar e montar o lab TertoOS (for dummies)

> Guia passo a passo para colocar a imagem **TertoOS v0.5.0** no EVE-NG e montar a
> topologia canônica (4 PE + CPE + BRAS). Estágio: **laboratório** (não produção).

Arquivos deste pacote:
- `eve-ng/tertoos.yml` — template do nó QEMU TertoOS.
- `tertoos-v0.5.0.qcow2` — a imagem (convertida do `sonic-vs.img.gz` da release).

---

## 1. Pré-requisitos
- Um servidor **EVE-NG** (Community ou Pro) com KVM habilitado.
- Acesso `root` por SSH ao EVE-NG.
- A imagem `tertoos-v0.5.0.qcow2` (vamos copiar — ver §5 do guia do lab / abaixo).

---

## 2. Instalar a imagem TertoOS no EVE-NG

No servidor EVE-NG, como **root**:

```bash
# 1) criar o diretório da imagem (o prefixo "tertoos-" casa com o template)
mkdir -p /opt/unetlab/addons/qemu/tertoos-v0.5.0

# 2) copiar a imagem para lá com o nome que o EVE-NG espera (disco virtio)
#    (o arquivo chega via scp da máquina local — ver §4)
cp /root/tertoos-v0.5.0.qcow2 /opt/unetlab/addons/qemu/tertoos-v0.5.0/virtioa.qcow2

# 3) instalar o template
cp tertoos.yml /opt/unetlab/html/templates/tertoos.yml

# 4) ajustar permissões (passo OBRIGATÓRIO no EVE-NG)
/opt/unetlab/wrappers/unl_wrapper -a fixpermissions
```

### 2a. Registrar o template no menu (EVE-NG CE)
Em algumas versões o template novo já aparece. Se NÃO aparecer no menu de nós, edite
`/opt/unetlab/html/includes/init.php` e adicione a linha no array `$node_templates`
(em ordem alfabética):
```php
'tertoos'         =>  'TertoOS',
```
Salve e recarregue a página do EVE-NG (Ctrl+F5).

### 2b. Alternativa sem template custom (mais simples)
Se preferir não mexer no `init.php`, use o template embutido **Linux**:
```bash
mkdir -p /opt/unetlab/addons/qemu/linux-tertoos-v0.5.0
cp tertoos-v0.5.0.qcow2 /opt/unetlab/addons/qemu/linux-tertoos-v0.5.0/virtioa.qcow2
/opt/unetlab/wrappers/unl_wrapper -a fixpermissions
```
No lab, adicione um nó **Linux**, escolha a imagem `tertoos-v0.5.0`, defina **8 interfaces**,
**4096 MB RAM**, **2 vCPU**, console **telnet**.

---

## 3. Montar a topologia no EVE-NG (GUI)

Crie um lab novo e adicione **4 nós TertoOS** (PE1–PE4). Se quiser o cenário PPPoE
completo, adicione também 2 nós **MikroTik CHR** (CPE e BRAS).

**Por nó TertoOS:** 8 interfaces, 4 GB RAM, 2 vCPU.

**Conexões (mapa de cabos):**

| De (nó/porta) | Para (nó/porta) | Papel |
|---|---|---|
| PE1 eth1 | PE2 eth0 | núcleo PE1↔PE2 |
| PE1 eth2 | PE3 eth0 | núcleo PE1↔PE3 |
| PE2 eth1 | PE4 eth0 | núcleo PE2↔PE4 |
| PE3 eth1 | PE4 eth1 | núcleo PE3↔PE4 |
| PE1 eth0 | CPE eth1 | acesso (PPPoE cliente) |
| PE4 eth0 | BRAS eth1 | acesso (PPPoE BRAS) |

> No EVE-NG, `eth0` do nó = **Ethernet0** do SONiC, `eth1` = **Ethernet4**, `eth2` =
> **Ethernet8** (o SONiC numera as front-panel de 4 em 4). O mapa de IPs/sub-redes é o
> mesmo do guia do lab (`LAB-TERTOOS-FOR-DUMMIES.md`, §2).

Inicie todos os nós, abra o console (telnet) e logue com **admin / tos**.

---

## 4. Copiar a imagem para o EVE-NG (resumo)

Fluxo: **servidor de build → máquina local → servidor EVE-NG** (a máquina local serve de
ponte). Comandos detalhados no guia do lab e no processo que executamos:

```bash
# 1) build -> local (na máquina local)
scp build@192.168.0.123:/tmp/tertoos-v0.5.0.qcow2  C:\dev\tertoos\eve-ng\

# 2) local -> EVE-NG (na máquina local; troque <IP-EVE-NG>)
scp C:\dev\tertoos\eve-ng\tertoos-v0.5.0.qcow2  root@<IP-EVE-NG>:/root/
```

---

## 5. Configurar (depois de subir)

A partir do console de cada PE, siga o **guia do lab** (`LAB-TERTOOS-FOR-DUMMIES.md`):
- §5.2 BGP + Route Reflector
- §5.3 BGP communities
- §6 forçar caminho SR (SR-TE)
- §7 PPPoE pelo fio L2

> No EVE-NG não há os alvos `make` do nosso sim (aqueles dependem do nosso servidor). No
> EVE-NG a configuração é feita **manualmente pela CLI** (klish) de cada nó, ou colando os
> blocos de comando do guia do lab.

---

## 6. Dicas / problemas comuns

- **Nó não dá boot:** confirme KVM (`kvm-ok`), RAM suficiente no EVE-NG e o nome do arquivo
  `virtioa.qcow2` (não `hda.qcow2`) — o template usa disco **virtio**.
- **Sem console:** o template usa serial→telnet; aguarde ~2–3 min o boot do SONiC.
- **Login:** `admin` / `tos`. Para `configure`, primeiro `enable`.
- **Permissões:** sempre rode `unl_wrapper -a fixpermissions` após copiar imagens/templates.
