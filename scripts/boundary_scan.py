#!/usr/bin/env python3
"""Platform-boundary scanner for engine/game migration (migration.md P0.5).

Finds SDL references under src/, classifies each hit against ALLOWLIST
(migration.md, decision D9), and reports three groups:

    * violations in files reachable from the build roots. These produce CI
        warnings; --fail makes the scan fail (Step 9).
  * allowed hits, listed separately so they do not read as problems.
  * hits in unreachable files. These are dead code that Step 1 removes, so
    they are reported as notices and never fail.

Categories
  sdl_name           an SDL_ or SDLK_ name, or a use of an SDL import alias, in code
  sdl_import         an import of platform/sdl/sdl.zig, or an SDL3 include
  backend_import     an import of another platform/sdl/ file from outside that folder
  engine_game_import an engine file imports a game implementation file
  private_engine_import a game file imports an engine implementation path directly
  game_sdl_import    a game file imports, aliases, names, or includes SDL

Scope:
  - Zig, C, and header files under src/ are scanned, based on reachability from
    src/main.zig, src/engine/core/engine.zig, src/tests.zig, and
    src/engine_api_test.zig.
  - Generated files, vendored dependencies, build scripts, and tools outside
    src/ are excluded unless explicitly added to a future build root.
  - scripts/boundary-fixtures/ contain isolated negative fixtures and are
    not part of the repository source reachability graph.
  - ALLOWLIST entries are narrow exceptions owned by migration.md D9.

Comments are removed, and string-literal bodies are blanked before matching,
so text in comments and strings does not count as a reference. SDL names that
appear only inside strings (for example a panic message) are listed as
information, not as violations.

Usage:
  python3 scripts/boundary_scan.py                 report; exit 0
  python3 scripts/boundary_scan.py --fail          exit 1 on reachable violations
  python3 scripts/boundary_scan.py --report FILE   also write the report to FILE
  python3 scripts/boundary_scan.py --self-test      run negative boundary fixtures
"""

import argparse
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
BUILD_ROOTS = ["src/main.zig", "src/engine/core/engine.zig", "src/tests.zig", "src/engine_api_test.zig"]
SDL_BACKEND_DIR = "src/engine/platform/sdl/"

ALL_CATEGORIES = {
    "sdl_name", "sdl_import", "backend_import",
    "engine_game_import", "private_engine_import", "game_sdl_import",
}

# (path or directory prefix ending in "/", allowed categories, reason).
# Source: migration.md D9. A file missing here must have no hits.
ALLOWLIST = [
    ("src/engine/platform/sdl/", ALL_CATEGORIES,
     "platform/sdl: the SDL implementation"),
    ("src/engine/platform/platform.zig", {"backend_import"},
     "platform facade: forwards engine-facing calls to the SDL backend"),
    ("src/engine/renderer/backends/sdl_gpu/", {"sdl_name", "sdl_import"},
     "SDL GPU backend: passes, shaders, textures, sprite pipelines and buffers"),
    ("src/tests.zig", {"backend_import"},
     "imports SDL backend modules so their platform tests are included"),
]

IMPORT_RE = re.compile(r'@import\("([^"]+)"\)')
DECL_IMPORT_RE = re.compile(r'(?:pub\s+)?const\s+(\w+)\s*=\s*@import\("([^"]+)"\)')
DECL_CIMPORT_RE = re.compile(r'(?:pub\s+)?const\s+(\w+)\s*=\s*@cImport\b')
SDL_NAME_RE = re.compile(r'\bSDLK?_[A-Za-z0-9_]+')
C_INCLUDE_SDL_RE = re.compile(r'#\s*include\s*[<"]SDL3/')


def classify_boundary_import(rel, resolved, target):
    """Return prohibited dependency categories for one Zig import."""
    cats = set()
    if rel.startswith("src/engine/") and resolved.startswith("src/game/"):
        cats.add("engine_game_import")
    if rel.startswith("src/game/"):
        if resolved.startswith("src/engine/"):
            cats.add("private_engine_import")
        if target in ("SDL", "sdl", "bairava_engine_sdl", "platform/sdl/sdl.zig"):
            cats.add("game_sdl_import")
        if resolved.startswith("src/engine/platform/sdl/"):
            cats.add("game_sdl_import")
    return cats


def allowed_for(rel):
    for key, cats, why in ALLOWLIST:
        if (key.endswith("/") and rel.startswith(key)) or rel == key:
            return set(cats), why
    return set(), None


def split_code(raw, is_c, in_block):
    """Return (code, strings, in_block). Comments are dropped; string bodies are blanked."""
    code, strings = [], []
    i, n = 0, len(raw)
    while i < n:
        if in_block:
            j = raw.find("*/", i)
            if j < 0:
                return "".join(code), strings, True
            i, in_block = j + 2, False
            continue
        if raw.startswith("//", i):
            break
        if is_c and raw.startswith("/*", i):
            in_block, i = True, i + 2
            continue
        ch = raw[i]
        if ch in ("'", '"'):
            j, buf = i + 1, []
            while j < n and raw[j] != ch:
                if raw[j] == "\\" and j + 1 < n:
                    buf.append(raw[j:j + 2])
                    j += 2
                else:
                    buf.append(raw[j])
                    j += 1
            strings.append("".join(buf))
            code.append(ch + ch)
            i = j + 1
            continue
        code.append(ch)
        i += 1
    return "".join(code), strings, in_block


def scan_file(path, rel):
    is_c = path.suffix in (".c", ".h")
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()

    parsed, in_block = [], False
    for raw in lines:
        if not is_c and raw.lstrip().startswith("\\\\"):  # Zig multi-line string
            parsed.append(("", [raw.lstrip()[2:]]))
            continue
        code, strings, in_block = split_code(raw, is_c, in_block)
        parsed.append((code, strings))

    all_strings = [s for _, ss in parsed for s in ss]
    file_is_sdl_cimport = any(s.startswith("SDL3/") for s in all_strings)

    sdl_aliases = set()
    if not is_c:
        for raw in lines:
            bare = raw.split("//", 1)[0]
            for m in DECL_IMPORT_RE.finditer(bare):
                name, target = m.group(1), m.group(2)
                base = target.rsplit("/", 1)[-1]
                if base == "sdl.zig":
                    sdl_aliases.add(name)
            if file_is_sdl_cimport:
                sdl_aliases.update(m.group(1) for m in DECL_CIMPORT_RE.finditer(bare))

    alias_use = {a: re.compile(r'(?<![\w.])' + re.escape(a) + r'\.[A-Za-z_]')
                 for a in sdl_aliases}

    hits, info = {}, []
    for lineno, (raw, (code, strings)) in enumerate(zip(lines, parsed), 1):
        cats = set()
        if is_c:
            if C_INCLUDE_SDL_RE.search(raw):
                cats.add("sdl_import")
                if rel.startswith("src/game/"):
                    cats.add("game_sdl_import")
        else:
            for m in IMPORT_RE.finditer(raw.split("//", 1)[0]):
                target = m.group(1)
                resolved = os.path.normpath(os.path.join(os.path.dirname(rel), target)).replace(os.sep, "/")
                base = os.path.basename(resolved)
                cats.update(classify_boundary_import(rel, resolved, target))
                if resolved.startswith(SDL_BACKEND_DIR) and not rel.startswith(SDL_BACKEND_DIR):
                    cats.add("sdl_import" if base == "sdl.zig" else "backend_import")
                    if rel.startswith("src/game/"):
                        cats.add("game_sdl_import")
                elif base == "sdl.zig":
                    cats.add("sdl_import")
            if "@cImport" in code and file_is_sdl_cimport:
                cats.add("sdl_import")
            if SDL_NAME_RE.search(code):
                cats.add("sdl_name")
                if rel.startswith("src/game/"):
                    cats.add("game_sdl_import")
            for a in sdl_aliases:
                if alias_use[a].search(code):
                    cats.add("sdl_name")
                    if rel.startswith("src/game/"):
                        cats.add("game_sdl_import")
        if cats:
            hits[lineno] = frozenset(cats)
        elif SDL_NAME_RE.search(" ".join(strings)):
            info.append(lineno)

    allowed, why = allowed_for(rel)
    return {"rel": rel, "is_c": is_c, "lines": lines, "hits": hits, "info": info,
            "allowed": allowed, "why": why}


def reachable_zig():
    seen, stack = set(), [ROOT / r for r in BUILD_ROOTS]
    while stack:
        p = stack.pop()
        if not p.is_file():
            continue
        rel = p.relative_to(ROOT).as_posix()
        if rel in seen:
            continue
        seen.add(rel)
        for raw in p.read_text(encoding="utf-8", errors="replace").splitlines():
            for m in IMPORT_RE.finditer(raw.split("//", 1)[0]):
                if not m.group(1).endswith(".zig"):
                    continue
                q = (p.parent / m.group(1)).resolve()
                try:
                    qrel = q.relative_to(ROOT).as_posix()
                except ValueError:
                    continue
                if qrel.startswith("src/"):
                    stack.append(q)
    return seen


def counts(hits):
    out = {}
    for cats in hits.values():
        for c in cats:
            out[c] = out.get(c, 0) + 1
    return out


def fmt_counts(c):
    category_order = (
        "sdl_name", "sdl_import", "backend_import",
        "engine_game_import", "private_engine_import", "game_sdl_import",
    )
    return ", ".join(f"{k} {c[k]}" for k in category_order if k in c)


def render(results, reach):
    out = []
    total = len(results)
    zig = sum(1 for r in results if not r["is_c"])
    live_zig = sum(1 for r in results if not r["is_c"] and r["rel"] in reach)
    out.append("Platform-boundary scan (migration.md P0.5)")
    out.append(f"Scanned {total} files under src/ ({zig} .zig, {total - zig} .c/.h).")
    out.append(f"Reachable .zig from {', '.join(BUILD_ROOTS)}: {live_zig}. "
               f"Unreachable .zig: {zig - live_zig}.")
    out.append("")

    viol_files, allowed_files, dead_files, info_files = [], [], [], []
    for r in sorted(results, key=lambda r: r["rel"]):
        live = r["is_c"] or r["rel"] in reach
        allowed_hits, viol_hits = {}, {}
        for ln, cats in r["hits"].items():
            a = cats & r["allowed"]
            v = cats - r["allowed"]
            if a:
                allowed_hits[ln] = a
            if v:
                viol_hits[ln] = v
        if r["info"]:
            info_files.append(r)
        if not live and r["hits"]:
            dead_files.append(r)
        elif live and viol_hits:
            viol_files.append((r, viol_hits))
        if live and allowed_hits:
            allowed_files.append((r, allowed_hits))

    viol_lines = sum(len(v) for _, v in viol_files)
    out.append(f"REACHABLE VIOLATIONS: {viol_lines} line(s) in {len(viol_files)} file(s) (warning)")
    for r, vh in viol_files:
        out.append(f"  {r['rel']}")
        out.append(f"      {fmt_counts(counts(vh))}")
        for ln in sorted(vh):
            out.append(f"      L{ln:<5} {','.join(sorted(vh[ln])):<22} {r['lines'][ln - 1].strip()[:140]}")
    out.append("")

    out.append("ALLOWED HITS (not violations)")
    for r, ah in allowed_files:
        out.append(f"  {r['rel']}: {fmt_counts(counts(ah))}  [{r['why']}]")
    out.append("")

    out.append("UNREACHABLE FILES WITH HITS (dead code; Step 1 candidates, not warned)")
    for r in dead_files:
        out.append(f"  {r['rel']}: {fmt_counts(counts(r['hits']))}")
    out.append("")

    out.append("INFORMATION: SDL names that appear only inside string literals")
    for r in info_files:
        out.append(f"  {r['rel']}: lines {', '.join(str(x) for x in r['info'])}")
    out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fail", action="store_true", help="exit 1 when reachable violations exist")
    ap.add_argument("--report", metavar="FILE", help="also write the report to FILE")
    ap.add_argument("--self-test", action="store_true", help="run built-in negative boundary fixtures")
    args = ap.parse_args()
    if args.self_test:
        cases = [
            ("engine-game-import.zig", "src/engine/core/example.zig", "engine_game_import"),
            ("game-private-engine-import.zig", "src/game/example.zig", "private_engine_import"),
            ("game-sdl-import.zig", "src/game/example.zig", "game_sdl_import"),
        ]
        failed = False
        fixture_dir = ROOT / "scripts" / "boundary-fixtures"
        for filename, virtual_rel, expected in cases:
            fixture = fixture_dir / filename
            if not fixture.is_file():
                print(f"self-test failed: missing fixture {fixture}", file=sys.stderr)
                failed = True
                continue
            raw = fixture.read_text(encoding="utf-8")
            matches = list(IMPORT_RE.finditer(raw))
            if not matches:
                print(f"self-test failed: {filename} has no import", file=sys.stderr)
                failed = True
                continue
            target = matches[0].group(1)
            resolved = os.path.normpath(os.path.join(os.path.dirname(virtual_rel), target)).replace(os.sep, "/")
            found = classify_boundary_import(virtual_rel, resolved, target)
            if virtual_rel.startswith("src/game/") and resolved.startswith(SDL_BACKEND_DIR):
                found.add("game_sdl_import")
            if expected not in found:
                print(f"self-test failed: {filename} did not report {expected}", file=sys.stderr)
                failed = True
        if failed:
            return 1
        print("Boundary self-test: 3/3 negative fixtures rejected")
        return 0

    if not SRC.is_dir():
        print(f"error: {SRC} not found", file=sys.stderr)
        return 2

    paths = sorted(p for p in SRC.rglob("*") if p.is_file() and p.suffix in (".zig", ".c", ".h"))
    results = [scan_file(p, p.relative_to(ROOT).as_posix()) for p in paths]
    reach = reachable_zig()
    text = render(results, reach)
    print(text)
    if args.report:
        Path(args.report).write_text(text + "\n", encoding="utf-8")

    violating = [r for r in results
                 if (r["is_c"] or r["rel"] in reach) and (set().union(*r["hits"].values()) - r["allowed"]
                                                          if r["hits"] else False)]

    if os.environ.get("GITHUB_ACTIONS") == "true":
        for r in violating:
            viol = [ln for ln, cats in r["hits"].items() if cats - r["allowed"]]
            cats = sorted(set().union(*(r["hits"][ln] for ln in viol)) - r["allowed"])
            print(f"::warning file={r['rel']},line={min(viol)},title=SDL boundary::"
                  f"{len(viol)} line(s) outside the allowlist ({', '.join(cats)}). "
                  f"Full list in the job log.")

    if args.fail and violating:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
