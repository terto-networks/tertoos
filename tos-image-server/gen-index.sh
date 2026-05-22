#!/usr/bin/env bash
# Gera /dados/tos-images/index.html (branded) listando as imagens TertoOS
# com tamanho, data e SHA256 (cacheado em .sha256 por arquivo).
# Uso: gen-index.sh [DIR]   (default: /dados/tos-images)
set -euo pipefail
DIR="${1:-/home/build/tos-images}"
cd "$DIR"
shopt -s nullglob

rows=""
for f in *.img.gz *.qcow2 *.img *.vmdk *.iso *.raw; do
    [ -e "$f" ] || continue
    sz=$(du -h "$f" | cut -f1)
    dt=$(date -r "$f" '+%Y-%m-%d %H:%M')
    shaf="$f.sha256"
    if [ ! -f "$shaf" ] || [ "$f" -nt "$shaf" ]; then
        echo "calculando sha256 de $f ..." >&2
        sha256sum "$f" | awk '{print $1}' > "$shaf"
    fi
    sha=$(cat "$shaf")
    rows="$rows<tr><td><a href=\"$f\">$f</a></td><td>$sz</td><td class=muted>$dt</td><td><code class=sha>$sha</code></td><td><a class=btn href=\"$f\">Baixar</a></td></tr>"
done
[ -n "$rows" ] || rows="<tr><td colspan=5 class=muted style='text-align:center;padding:2rem'>Nenhuma imagem publicada ainda.</td></tr>"
gen=$(date '+%Y-%m-%d %H:%M')

cat > index.html.tmp <<HTML
<!DOCTYPE html><html lang="pt-BR"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>TertoOS — Imagens</title>
<style>
:root{--brand:#10b981;--brand-d:#059669;--ink:#1b2433;--ink2:#5b6678;--bg:#f4f6f9;--line:#e5e8ee}
*{box-sizing:border-box}body{margin:0;font-family:Inter,system-ui,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--ink)}
header{background:#0f1b2d;color:#fff;padding:1.1rem 1.5rem;display:flex;align-items:center;gap:.8rem}
.logo{width:38px;height:38px;border-radius:10px;background:linear-gradient(135deg,var(--brand),var(--brand-d));display:grid;place-items:center;font-weight:800;font-size:20px;box-shadow:0 2px 8px rgba(16,185,129,.4)}
header h1{font-size:18px;margin:0}header small{color:#7c8ca3;display:block;font-weight:500}
main{max-width:1100px;margin:1.5rem auto;padding:0 1.25rem}
.card{background:#fff;border:1px solid var(--line);border-radius:12px;box-shadow:0 1px 3px rgba(16,24,40,.08);overflow:hidden}
table{border-collapse:collapse;width:100%}
th{font-size:11.5px;text-transform:uppercase;letter-spacing:.4px;color:#8a94a6;text-align:left;padding:.7rem .9rem;border-bottom:1px solid var(--line);background:#fafbfc}
td{padding:.7rem .9rem;border-bottom:1px solid var(--line);vertical-align:middle}
tr:last-child td{border-bottom:none}tr:hover td{background:#f8fafc}
a{color:var(--brand-d);text-decoration:none;font-weight:600}a:hover{text-decoration:underline}
.muted{color:#8a94a6}.sha{font-size:11px;color:#5b6678;word-break:break-all}
.btn{display:inline-block;background:var(--brand);color:#fff;padding:.35rem .8rem;border-radius:8px;font-size:13px}
.btn:hover{background:var(--brand-d);text-decoration:none}
.note{color:var(--ink2);font-size:13px;margin:.4rem 0 1rem}
footer{max-width:1100px;margin:1rem auto;padding:0 1.25rem;color:#8a94a6;font-size:12px}
code{font-family:ui-monospace,Consolas,monospace}
</style></head><body>
<header><div class="logo">T</div><div><h1>TertoOS — Imagens</h1><small>Servidor interno de downloads</small></div></header>
<main>
  <p class="note">Imagens bootáveis do TertoOS para uso interno (lab / EVE-NG / KVM). Verifique o <strong>SHA256</strong> após baixar.</p>
  <div class="card"><table>
    <thead><tr><th>Arquivo</th><th>Tamanho</th><th>Data</th><th>SHA256</th><th></th></tr></thead>
    <tbody>$rows</tbody>
  </table></div>
</main>
<footer>Gerado em $gen · TertoOS / Terto Networks · acesso restrito à rede interna</footer>
</body></html>
HTML
mv index.html.tmp index.html
echo "index.html gerado em $DIR"
