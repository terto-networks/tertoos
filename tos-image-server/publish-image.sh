#!/usr/bin/env bash
# Publica a imagem TOS recém-buildada no servidor de downloads e regenera o índice.
# Uso: publish-image.sh <versao> [origem.img.gz]
#   ex: publish-image.sh v0.5.1
#       publish-image.sh v0.5.1 /dados/tertoos/target/sonic-vs.img.gz
set -euo pipefail
VER="${1:?uso: publish-image.sh <versao>  (ex: v0.5.1)}"
SRC="${2:-/dados/tertoos/target/sonic-vs.img.gz}"
DSTDIR=/home/build/tos-images
DST="$DSTDIR/tertoos-vs-$VER.img.gz"

[ -f "$SRC" ] || { echo "erro: nao encontrei $SRC" >&2; exit 1; }
mkdir -p "$DSTDIR"
# hardlink (mesmo filesystem = zero espaco extra); fallback copia se cross-fs.
ln -f "$SRC" "$DST" 2>/dev/null || cp -f "$SRC" "$DST"
echo "publicado: $DST"

# regenera o indice (recalcula sha256 do novo arquivo)
"$(dirname "$0")/gen-index.sh" "$DSTDIR"
echo "pronto. veja em http://192.168.0.123:8088/"
