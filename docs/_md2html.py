#!/usr/bin/env python3
# Conversor md->html minimalista (stdlib) para a doc do lab TertoOS.
# Cobre: headings, tabelas, code fences, blockquote, listas, hr, **bold**, `code`, [t](u).
import sys, re, html

def inline(s):
    s = html.escape(s)
    s = re.sub(r'`([^`]+)`', r'<code>\1</code>', s)
    s = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', s)
    s = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', s)
    return s

def convert(md):
    out, i, lines = [], 0, md.split('\n')
    while i < len(lines):
        ln = lines[i]
        # code fence
        if ln.startswith('```'):
            i += 1; buf = []
            while i < len(lines) and not lines[i].startswith('```'):
                buf.append(html.escape(lines[i])); i += 1
            i += 1
            out.append('<pre><code>' + '\n'.join(buf) + '</code></pre>')
            continue
        # table
        if ln.strip().startswith('|') and i+1 < len(lines) and re.match(r'^\s*\|[\s:|-]+\|\s*$', lines[i+1]):
            hdr = [c.strip() for c in ln.strip().strip('|').split('|')]
            i += 2; rows = []
            while i < len(lines) and lines[i].strip().startswith('|'):
                rows.append([c.strip() for c in lines[i].strip().strip('|').split('|')]); i += 1
            t = ['<table><thead><tr>'] + [f'<th>{inline(c)}</th>' for c in hdr] + ['</tr></thead><tbody>']
            for r in rows:
                t.append('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>')
            t.append('</tbody></table>')
            out.append(''.join(t)); continue
        # heading
        m = re.match(r'^(#{1,6})\s+(.*)$', ln)
        if m:
            lvl = len(m.group(1)); out.append(f'<h{lvl}>{inline(m.group(2))}</h{lvl}>'); i += 1; continue
        # hr
        if re.match(r'^---+\s*$', ln):
            out.append('<hr>'); i += 1; continue
        # blockquote
        if ln.startswith('>'):
            buf = []
            while i < len(lines) and lines[i].startswith('>'):
                buf.append(inline(lines[i].lstrip('>').strip())); i += 1
            out.append('<blockquote>' + '<br>'.join(buf) + '</blockquote>'); continue
        # list
        if re.match(r'^\s*[-*]\s+', ln):
            buf = []
            while i < len(lines) and re.match(r'^\s*[-*]\s+', lines[i]):
                buf.append('<li>' + inline(re.sub(r'^\s*[-*]\s+', '', lines[i])) + '</li>'); i += 1
            out.append('<ul>' + ''.join(buf) + '</ul>'); continue
        # blank
        if ln.strip() == '':
            i += 1; continue
        # paragraph
        buf = []
        while i < len(lines) and lines[i].strip() != '' and not lines[i].startswith(('#', '>', '```', '|', '---')) and not re.match(r'^\s*[-*]\s+', lines[i]):
            buf.append(inline(lines[i])); i += 1
        out.append('<p>' + '<br>'.join(buf) + '</p>')
    return '\n'.join(out)

CSS = """body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;max-width:980px;margin:2rem auto;padding:0 1rem;line-height:1.55;color:#1b1f23}
h1,h2,h3{border-bottom:1px solid #eaecef;padding-bottom:.3em;margin-top:1.6em}h1{color:#0b5}
code{background:#f6f8fa;padding:.15em .35em;border-radius:4px;font-size:.9em}
pre{background:#0d1117;color:#e6edf3;padding:1rem;border-radius:8px;overflow:auto}pre code{background:none;color:inherit;padding:0}
table{border-collapse:collapse;width:100%;margin:1em 0}th,td{border:1px solid #d0d7de;padding:.45em .7em;text-align:left}th{background:#f6f8fa}
blockquote{border-left:4px solid #0b5;background:#f6fff9;margin:1em 0;padding:.5em 1em;color:#444}
a{color:#0969da}hr{border:0;border-top:1px solid #eaecef;margin:2em 0}"""

src, dst = sys.argv[1], sys.argv[2]
md = open(src, encoding='utf-8').read()
title = (md.split('\n', 1)[0]).lstrip('# ').strip()
htmldoc = f"<!DOCTYPE html><html lang='pt-BR'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>{html.escape(title)}</title><style>{CSS}</style></head><body>\n{convert(md)}\n</body></html>"
open(dst, 'w', encoding='utf-8').write(htmldoc)
print(f"OK -> {dst}")
