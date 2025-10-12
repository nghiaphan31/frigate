#!/usr/bin/env python3
import argparse, pathlib, json, html

def load_tsv(p):
    rows=[]
    with open(p,'r',encoding='utf-8',errors='ignore') as f:
        header=f.readline().rstrip('\n').split('\t')
        cols={h:i for i,h in enumerate(header)}
        for line in f:
            if not line.strip(): continue
            parts=line.rstrip('\n').split('\t')
            if len(parts) < len(cols): continue
            # mark depth count size_bytes prefix
            mark   = parts[0].strip()
            depth  = int(parts[cols.get('depth',1)])
            count  = int(parts[cols.get('count',2)])
            size_b = int(parts[cols.get('size_bytes',3)])
            prefix = parts[cols.get('prefix',4)].strip()
            rows.append({"mark":mark,"depth":depth,"count":count,"size":size_b,"prefix":prefix})
    return rows

TEMPLATE = """<!doctype html>
<html lang="fr">
<meta charset="utf-8">
<title>Tree annotator</title>
<style>
  body{font:14px system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif; margin:16px; }
  .toolbar{position:sticky; top:0; background:#fff; padding:8px 0; border-bottom:1px solid #eee; margin-bottom:8px}
  button{padding:6px 10px; margin-right:6px; border:1px solid #ddd; border-radius:8px; cursor:pointer;}
  .node{margin:4px 0;}
  .meta{color:#666; font-size:12px; margin-left:8px}
  details>summary{cursor:pointer}
  .mark{margin-left:12px; font-size:12px}
  .mark label{margin-right:8px}
  .count{display:inline-block; min-width:60px}
  .prefix{font-family:ui-monospace, SFMono-Regular, Menlo, Consolas, monospace}
  .xmark{background:#fee;border:1px solid #fbb; padding:0 4px; border-radius:5px}
  .kmark{background:#eef;border:1px solid #bbf; padding:0 4px; border-radius:5px}
  .muted{opacity:.5}
</style>
<div class="toolbar">
  <button id="btnExpand">Expand all</button>
  <button id="btnCollapse">Collapse all</button>
  <button id="btnExport">Export marks (TSV)</button>
  <span id="stats" class="meta"></span>
</div>
<div id="tree"></div>
<script>
const DATA = __DATA__;
function buildTree(rows){
  // Build nodes dict by prefix
  const nodes = new Map(); // prefix -> node
  for(const r of rows){
    nodes.set(r.prefix, {prefix:r.prefix, depth:r.depth, count:r.count, size:r.size, mark:"", children:[]});
  }
  // connect parents
  const roots=[];
  for(const n of nodes.values()){
    const p = n.prefix.includes('/') ? n.prefix.slice(0,n.prefix.lastIndexOf('/')) : null;
    if(p && nodes.has(p)){ nodes.get(p).children.push(n); }
    else { roots.push(n); }
  }
  // sort children alpha
  function sortRec(n){ n.children.sort((a,b)=> a.prefix.localeCompare(b.prefix)); n.children.forEach(sortRec); }
  roots.sort((a,b)=> a.prefix.localeCompare(b.prefix)); roots.forEach(sortRec);
  return roots;
}
function human(n){ if(!n) return "-"; const m = n/1024/1024; if(m<1024) return m.toFixed(1)+" MB"; return (m/1024).toFixed(2)+" GB"; }

function renderNode(n){
  const details = document.createElement('details');
  if(n.children.length) details.open=false; // collapsed by default
  details.className = 'node';
  const sum = document.createElement('summary');
  const count = document.createElement('span'); count.className="count"; count.textContent = "["+n.count+"]";
  const pref = document.createElement('span'); pref.className="prefix"; pref.textContent = n.prefix || "(root)";
  const meta = document.createElement('span'); meta.className="meta"; meta.textContent = "size: "+human(n.size);
  sum.append(count, pref, meta);
  // mark radios
  const mark = document.createElement('span'); mark.className='mark';
  mark.innerHTML = `
    <label><input type="radio" name="m:${n.prefix}" value="" checked> none</label>
    <label class="xmark"><input type="radio" name="m:${n.prefix}" value="X"> X exclude subtree</label>
    <label class="kmark"><input type="radio" name="m:${n.prefix}" value="K"> K keep subtree</label>`;
  sum.append(mark);
  details.append(sum);
  if(n.children.length){
    const div = document.createElement('div');
    n.children.forEach(c => div.append(renderNode(c)));
    details.append(div);
  }
  return details;
}
function collectMarks(){
  const marks = [];
  const inputs = document.querySelectorAll('input[type=radio]:checked');
  inputs.forEach(inp=>{
    if(!inp.value) return;
    const prefix = inp.name.slice(2);
    const row = window._rowIndex.get(prefix);
    marks.push({mark:inp.value, depth:row.depth, count:row.count, size:row.size, prefix});
  });
  return marks;
}
function downloadTSV(rows){
  const header = "mark\tdepth\tcount\tsize_bytes\tprefix\\n";
  const lines = rows.map(r=> [r.mark, r.depth, r.count||0, r.size||0, r.prefix].join('\\t')).join('\\n');
  const blob = new Blob([header+lines], {type:'text/tab-separated-values;charset=utf-8'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = "tree.mark.tsv";
  a.click();
  URL.revokeObjectURL(a.href);
}
function expandAll(flag){
  document.querySelectorAll('details').forEach(d=>{ if(flag) d.setAttribute('open', 'open'); else d.removeAttribute('open'); });
}
(function init(){
  const roots = buildTree(DATA);
  // index by prefix (for depth on export)
  window._rowIndex = new Map(); DATA.forEach(r=> window._rowIndex.set(r.prefix, r));
  const tree = document.getElementById('tree');
  roots.forEach(r => tree.append(renderNode(r)));
  document.getElementById('btnExpand').onclick = ()=> expandAll(true);
  document.getElementById('btnCollapse').onclick = ()=> expandAll(false);
  document.getElementById('btnExport').onclick = ()=>{
    const rows = collectMarks();
    downloadTSV(rows);
  };
  document.getElementById('stats').textContent = `nodes: ${DATA.length}`;
})();
</script>
"""
def main():
    ap = argparse.ArgumentParser(description="Convertit tree.tsv en annotateur HTML interactif (expand/collapse + export TSV).")
    ap.add_argument("--tsv", required=True, help="tree.tsv depuis cascade_tree.py")
    ap.add_argument("--out", required=True, help="chemin du HTML de sortie")
    args = ap.parse_args()

    rows = load_tsv(args.tsv)
    html_out = TEMPLATE.replace("__DATA__", json.dumps(rows, ensure_ascii=False))
    pathlib.Path(args.out).write_text(html_out, encoding='utf-8')
    print(f"✅ Wrote {args.out}")

if __name__ == "__main__":
    main()
