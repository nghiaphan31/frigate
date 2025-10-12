#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Tree Annotator TUI — no browser, big-file friendly.
- Charge un TSV (délimiteur auto: tab, virgule, point-virgule, ou espaces multiples).
- Détecte la colonne chemin parmi: path, full_path, node, folder, dir ; sinon tente parent+name ou colonnes lvlN/ancestorN.
- Affiche l'arborescence (indent), couleurs, scroll, expand/collapse.
- Marquage: K (keep), X (exclude), C (clear). Marquage en cascade visuel (hérité).
- Recherche: '/' puis texte ou /regex/ ; 'n' (suivant), 'N' (précédent).
- Sauvegarde TSV: path, mark, comment (vide).
- Résolution héritage visuelle: un X ancêtre rend les enfants "hérités X" (affichés en rouge doux). Le fichier d’export n’écrit que les marquages explicites.
- Touches: ↑/↓, PgUp/PgDn, Home/End, ←/→/E (collapse/expand), K/X/C, /, n/N, s (save), q (quit).
"""

import curses, locale, sys, csv, re
from pathlib import Path

locale.setlocale(locale.LC_ALL, "")

# ---------- chargement TSV robuste ----------
def read_text_smart(p: Path) -> str:
    raw = p.read_bytes()
    for enc in ("utf-8-sig","utf-8","utf-16","utf-16le","utf-16be"):
        try: return raw.decode(enc).replace("\r\n","\n").replace("\r","\n")
        except UnicodeDecodeError: continue
    raise RuntimeError("Cannot decode file: %s" % p)

def detect_delim(header_line: str) -> str:
    if "\t" in header_line: return "\t"
    if ","  in header_line: return ","
    if ";"  in header_line: return ";"
    # espace(s) -> on compresse en tab
    return None

ALIASES = ['path','full_path','node','folder','dir']

def parse_tsv_any(p: Path):
    txt = read_text_smart(p)
    if not txt.strip(): return [], []
    lines = [ln for ln in txt.split("\n") if ln.strip()]
    head = lines[0]
    delim = detect_delim(head)
    if delim is None:
        # compresse espaces multiples -> tab
        import re as _re
        lines = [_re.sub(r"[ ]{2,}", "\t", ln) for ln in lines]
        delim = "\t"
    hdr = [h.strip() for h in lines[0].split(delim)]
    hdr_low = [h.lower() for h in hdr]
    rows = [ln.split(delim) for ln in lines[1:]]

    # localise colonne chemin
    i_path = next((i for i,h in enumerate(hdr_low) if h in ALIASES), -1)
    i_parent = hdr_low.index("parent") if "parent" in hdr_low else -1
    i_name   = hdr_low.index("name")   if "name"   in hdr_low else -1
    lvl_cols = [i for i,h in enumerate(hdr_low) if re.fullmatch(r"(lvl|level|ancestor|anc)[ _-]?\d+", h)]
    lvl_cols.sort(key=lambda i: int(re.findall(r"\d+", hdr_low[i])[0]) if re.findall(r"\d+", hdr_low[i]) else 0)

    paths = []
    for parts in rows:
        def at(i): return parts[i].strip() if 0 <= i < len(parts) else ""
        raw = ""
        if i_path >= 0:
            raw = at(i_path)
        elif i_parent >=0 and i_name >=0:
            raw = (at(i_parent).rstrip("/") + "/" + at(i_name).lstrip("/")).strip()
        elif lvl_cols:
            segs = [at(i).strip("/").strip() for i in lvl_cols if at(i)]
            raw = "/" + "/".join([s for s in segs if s])
        else:
            continue
        if not raw: continue
        if raw.startswith("./"): raw = raw[2:]
        raw = re.sub(r"/+","/", raw)
        if not raw.startswith("/"): raw = "/" + raw
        # on normalise les noeuds comme des dossiers (affichage arborescence)
        if not raw.endswith("/"): raw = raw  # ne force pas / à la fin
        paths.append(raw)
    return hdr, paths

# ---------- modèle d'arbre ----------
class Node:
    __slots__ = ("name","path","depth","children","expanded")
    def __init__(self, name, path, depth):
        self.name=name; self.path=path; self.depth=depth
        self.children = {}  # name -> Node
        self.expanded = depth < 2  # par défaut: expand jusque profondeur 1

def build_tree(paths):
    root = Node("/", "/", 0)
    for p in sorted(set(paths)):
        segs = [s for s in p.strip("/").split("/") if s]
        cur = root; curpath = ""
        for i,seg in enumerate(segs):
            curpath = "/" + "/".join(segs[:i+1])
            if seg not in cur.children:
                cur.children[seg] = Node(seg, curpath, i+1)
            cur = cur.children[seg]
    return root

def flatten_visible(root, marks, filter_re=None, only_marked=False, collapsed=set()):
    """Retourne liste des noeuds visibles (DFS préfixe) selon expansion/collapse, filtre et marquages."""
    out=[]
    def passes_filter(n):
        if only_marked and n.path not in marks: return False
        if filter_re and not filter_re.search(n.path): return False
        return True
    def dfs(n):
        if n is not root:
            if not passes_filter(n):
                # si filtré, on peut encore montrer l'ancêtre si des descendants matchent ? -> pour simplicité, on masque.
                pass
            out.append(n)
        if n.path in collapsed or not n.expanded: return
        for k in sorted(n.children.keys(), key=lambda s:s.lower()):
            dfs(n.children[k])
    # root invisible, on déroule direct ses enfants
    for k in sorted(root.children.keys(), key=lambda s:s.lower()):
        dfs(root.children[k])
    return out

# ---------- TUI ----------
class App:
    def __init__(self, stdscr, paths, out_path):
        self.stdscr = stdscr
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_WHITE, -1)     # normal
        curses.init_pair(2, curses.COLOR_GREEN, -1)     # keep
        curses.init_pair(3, curses.COLOR_RED, -1)       # exclude
        curses.init_pair(4, curses.COLOR_CYAN, -1)      # folder
        curses.init_pair(5, curses.COLOR_YELLOW, -1)    # status
        curses.init_pair(6, curses.COLOR_MAGENTA, -1)   # search
        self.color_normal = curses.color_pair(1)
        self.color_keep   = curses.color_pair(2)
        self.color_excl   = curses.color_pair(3)
        self.color_fold   = curses.color_pair(4)
        self.color_status = curses.color_pair(5)
        self.color_search = curses.color_pair(6)

        self.root = build_tree(paths)
        
        self.marks = {}          # path -> 'K' | 'X'

        # preload existing marks if out_path exists
        def load_existing_marks(path):
            try:
                import csv
                from pathlib import Path
                fp = Path(path)
                if not fp.exists(): return {}
                with fp.open('r', encoding='utf-8', newline='') as f:
                    r = csv.DictReader(f, delimiter='\t')
                    m = {}
                    for row in r:
                        pth = (row.get('path') or '').strip()
                        mk  = (row.get('mark') or '').strip().upper()
                        if pth and mk in ('K','X'): m[pth] = mk
                    return m
            except Exception:
                return {}

        self.marks.update(load_existing_marks(out_path))
    
        self.collapsed = set()   # chemins manuellement collapsés
        self.filter_re = None
        self.only_marked = False
        self.out_path = out_path
        self.visible = flatten_visible(self.root, self.marks, self.filter_re, self.only_marked, self.collapsed)
        self.sel = 0
        self.dirty = False
        self.search_hits = []
        self.search_idx = -1

    # héritage effectif pour affichage (cascade)
    def inherited_mark(self, path):
        # si explicite:
        if path in self.marks: return self.marks[path]
        # sinon: regarde ancêtres
        p = path
        while True:
            if p in self.marks and self.marks[p] == 'X': return 'x'  # hérité X (minuscule pour visuel)
            # keep hérité n’impose pas une couleur forte; on laisse neutre
            if p == "/": break
            p = "/" if p.count("/")<=1 else p.rsplit("/",1)[0]
        return ''

    def recompute(self):
        self.visible = flatten_visible(self.root, self.marks, self.filter_re, self.only_marked, self.collapsed)
        if self.sel >= len(self.visible): self.sel = max(0, len(self.visible)-1)

    def toggle_expand(self, node):
        if node.path in self.collapsed:
            self.collapsed.remove(node.path)
            node.expanded = True
        else:
            self.collapsed.add(node.path)
            node.expanded = False
        self.recompute()

    def expand_all(self, depth=None):
        def dfs(n):
            if depth is None or n.depth <= depth:
                n.expanded=True; self.collapsed.discard(n.path)
            for ch in n.children.values(): dfs(ch)
        dfs(self.root); self.recompute()

    def collapse_all(self, depth=2):
        def dfs(n):
            if n.depth <= depth:
                n.expanded=False; self.collapsed.add(n.path)
            for ch in n.children.values(): dfs(ch)
        self.collapsed=set(); dfs(self.root); self.recompute()

    def mark(self, node, val):  # 'K' | 'X' | ''
        if val:
            self.marks[node.path]=val
        else:
            self.marks.pop(node.path, None)
        self.dirty=True
        self.recompute()

    def draw(self):
        self.stdscr.erase()
        h, w = self.stdscr.getmaxyx()
        w = max(1, w-1)  # clamp width to avoid addnstr ERR on wide chars

        # header
        status = f"[↑↓ PgUp/PgDn] nav  [←/→/E] fold  [K/X/C] mark  [/ ] search  [n/N] next/prev  [s] save  [q] quit"
        self.stdscr.addnstr(0, 0, status.ljust(w-1), w-1, self.color_status | curses.A_BOLD)

        # stats
        k = sum(1 for v in self.marks.values() if v=='K')
        x = sum(1 for v in self.marks.values() if v=='X')
        info = f"K:{k}  X:{x}  total:{len(self.visible)}"
        self.stdscr.addnstr(1, 0, info.ljust(w-1), w-1, self.color_status)

        # viewport
        top = 2
        rows = h - top - 1
        if rows <= 0: self.stdscr.refresh(); return

        start = max(0, min(self.sel - rows//2, max(0, len(self.visible)-rows)))
        end = min(len(self.visible), start+rows)

        for i in range(start, end):
            y = top + (i-start)
            node = self.visible[i]
            is_sel = (i == self.sel)
            inh = self.inherited_mark(node.path)  # '', 'x'
            expl = self.marks.get(node.path, '')

            mark = expl or inh
            if mark == 'K': col = self.color_keep
            elif mark in ('X','x'): col = self.color_excl
            else: col = self.color_normal

            # indentation & chevron
            indent = "  " * max(0, node.depth)
            chevron = "▸" if (node.path in self.collapsed or not node.expanded) and node.children else "▾" if node.children else "•"
            label = f"{indent}{chevron} {node.name or '/'}"
            if node.children: col_label = self.color_fold
            else: col_label = col

            if is_sel:
                self.stdscr.addnstr(y, 0, ">", 1, col | curses.A_REVERSE)
            else:
                self.stdscr.addnstr(y, 0, " ", 1, col)

            self.stdscr.addnstr(y, 2, (mark or " ").ljust(2), 2, col | (curses.A_REVERSE if is_sel else 0))
            self.stdscr.addnstr(y, 5, label[:w-5], w-5, col_label | (curses.A_REVERSE if is_sel else 0))

        # footer (chemin sélectionné)
        cur = self.visible[self.sel] if self.visible else None
        foot = (cur.path if cur else "").ljust(w)
        try:
            self.stdscr.addnstr(h-1, 0, foot, w, self.color_search)
        except curses.error:
            pass

        self.stdscr.refresh()

    def input_line(self, prompt):
        h,w = self.stdscr.getmaxyx()
        self.stdscr.addnstr(h-1, 0, " " * (w), w)
        self.stdscr.addnstr(h-1, 0, prompt, w, self.color_search | curses.A_BOLD)
        curses.echo(); curses.curs_set(1)
        try:
            s = self.stdscr.getstr(h-1, len(prompt), w-len(prompt)-1)
        finally:
            curses.noecho(); curses.curs_set(0)
        try: return s.decode("utf-8")
        except: return ""

    def do_search(self):
        s = self.input_line("Rechercher (texte ou /regex/): ")
        s = s.strip()
        if not s: self.filter_re=None; self.search_hits=[]; self.search_idx=-1; self.recompute(); return
        if s.startswith("/") and s.endswith("/") and len(s)>2:
            try: rx = re.compile(s[1:-1], re.I)
            except: rx = re.compile(re.escape(s), re.I)
        else:
            rx = re.compile(re.escape(s), re.I)
        self.filter_re = rx
        self.recompute()
        # prépare hits pour n/N
        self.search_hits = [i for i,n in enumerate(self.visible) if rx.search(n.path)]
        self.search_idx = 0 if self.search_hits else -1
        if self.search_idx>=0: self.sel = self.search_hits[self.search_idx]

    def next_hit(self, backwards=False):
        if not self.search_hits: return
        if backwards:
            self.search_idx = (self.search_idx - 1) % len(self.search_hits)
        else:
            self.search_idx = (self.search_idx + 1) % len(self.search_hits)
        self.sel = self.search_hits[self.search_idx]

    def save(self):
        out = Path(self.out_path)
        rows = sorted(self.marks.items(), key=lambda kv: kv[0].lower())
        with out.open("w", encoding="utf-8", newline="") as w:
            w.write("path\tmark\tcomment\n")
            for p,m in rows:
                w.write(f"{p}\t{m}\t\n")
        self.dirty=False

    def run(self):
        curses.curs_set(0)
        while True:
            self.draw()
            ch = self.stdscr.getch()
            if ch in (ord('q'), 27):  # q ou ESC
                if self.dirty:
                    # demande rapide
                    resp = self.input_line("Des changements non sauvés. Quitter sans sauver ? (y/N): ").strip().lower()
                    if resp != 'y': continue
                break
            elif ch in (curses.KEY_DOWN, ord('j')):
                if self.sel < len(self.visible)-1: self.sel += 1
            elif ch in (curses.KEY_UP, ord('k')):
                if self.sel > 0: self.sel -= 1
            elif ch in (curses.KEY_NPAGE,):
                self.sel = min(self.sel+20, max(0,len(self.visible)-1))
            elif ch in (curses.KEY_PPAGE,):
                self.sel = max(self.sel-20, 0)
            elif ch in (curses.KEY_HOME,):
                self.sel = 0
            elif ch in (curses.KEY_END,):
                self.sel = max(0, len(self.visible)-1)
            elif ch in (curses.KEY_LEFT, ord('h'), ord('E'), ord('e')):
                if self.visible:
                    self.toggle_expand(self.visible[self.sel])
            elif ch in (curses.KEY_RIGHT, ord('l')):
                if self.visible:
                    self.toggle_expand(self.visible[self.sel])
            elif ch in (ord('K'), ord('k')):
                if self.visible: self.mark(self.visible[self.sel], 'K')
            elif ch in (ord('X'), ord('x')):
                if self.visible: self.mark(self.visible[self.sel], 'X')
            elif ch in (ord('C'), ord('c'), curses.KEY_BACKSPACE, 127):
                if self.visible: self.mark(self.visible[self.sel], '')
            elif ch in (ord('/'),):
                self.do_search()
            elif ch in (ord('n'),):
                self.next_hit(False)
            elif ch in (ord('N'),):
                self.next_hit(True)
            elif ch in (ord('S'), ord('s')):
                self.save()
            elif ch == ord('A'):   # expand all
                self.expand_all()
            elif ch == ord('Z'):   # collapse all (depth 2)
                self.collapse_all(2)
            self.recompute()

def main():
    import argparse
    ap = argparse.ArgumentParser(description="Tree Annotator TUI (cascading K/X)")
    ap.add_argument("--tsv", required=True, help="fichier TSV issu de cascade_tree.py (ou équivalent)")
    ap.add_argument("--out", default="tree.mark.tsv", help="sortie TSV des marquages")
    args = ap.parse_args()

    tsv = Path(args.tsv)
    if not tsv.exists(): print("TSV introuvable:", tsv); sys.exit(1)
    hdr, paths = parse_tsv_any(tsv)
    if not paths:
        print("Aucun chemin détecté dans", tsv)
        sys.exit(1)

    curses.wrapper(lambda stdscr: App(stdscr, paths, args.out).run())
    print("Done.")

if __name__ == "__main__":
    main()
