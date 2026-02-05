#!/usr/bin/env python3
import argparse, re, subprocess, sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Set

SWIFT_EXT = ".swift"

TYPE_DECL_RE = re.compile(r'^\s*(public\s+|internal\s+|fileprivate\s+|private\s+)?(final\s+)?(class|struct|enum|actor|protocol)\s+([A-Za-z_]\w*)', re.M)
EXT_DECL_RE  = re.compile(r'^\s*extension\s+([A-Za-z_]\w*)', re.M)
HAS_MAIN_RE  = re.compile(r'^\s*@main\b', re.M)

# Pull .swift paths from xcodebuild output (works when we force a clean build)
SWIFT_PATH_RE_ABS = re.compile(r'(/[^ \n\t"]+\.swift)\b')
SWIFT_PATH_RE_REL = re.compile(r'\b([A-Za-z0-9_./-]+\.swift)\b')

@dataclass
class SwiftFileInfo:
    rel: str
    declared_types: List[str]
    extended_types: List[str]
    has_main: bool

@dataclass
class Result:
    rel: str
    compiled: bool
    verdict: str
    symbol_hits: int
    notes: List[str]

def read_text(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="ignore")

def run_clean_build(project: str, scheme: str, config: str, derived: str, buildlog: str) -> None:
    subprocess.run(["rm", "-rf", derived], check=False)
    cmd = [
        "xcodebuild",
        "-project", project,
        "-scheme", scheme,
        "-configuration", config,
        "-derivedDataPath", derived,
        "clean", "build"
    ]
    # capture output to file so we can parse it deterministically
    with open(buildlog, "w", encoding="utf-8", errors="ignore") as f:
        subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, text=True)

def extract_compiled_swift_from_buildlog(repo_root: Path, buildlog: str) -> Set[str]:
    txt = Path(buildlog).read_text(encoding="utf-8", errors="ignore")
    compiled: Set[str] = set()

    # absolute paths
    for sp in SWIFT_PATH_RE_ABS.findall(txt):
        p = Path(sp)
        if p.exists():
            try:
                compiled.add(str(p.resolve().relative_to(repo_root)))
            except Exception:
                pass

    # repo-relative paths (often show up as "ColorCoded/Foo.swift")
    for sp in SWIFT_PATH_RE_REL.findall(txt):
        cand = (repo_root / sp).resolve()
        if cand.exists():
            try:
                compiled.add(str(cand.relative_to(repo_root)))
            except Exception:
                pass

    return compiled

def collect_swift_infos(src_root: Path) -> List[SwiftFileInfo]:
    repo_root = src_root.parent
    infos: List[SwiftFileInfo] = []
    for p in sorted(src_root.rglob(f"*{SWIFT_EXT}")):
        txt = read_text(p)
        declared = sorted(set(m.group(4) for m in TYPE_DECL_RE.finditer(txt)))
        extended = sorted(set(m.group(1) for m in EXT_DECL_RE.finditer(txt)))
        has_main = bool(HAS_MAIN_RE.search(txt))
        infos.append(SwiftFileInfo(
            rel=str(p.resolve().relative_to(repo_root)),
            declared_types=declared,
            extended_types=extended,
            has_main=has_main
        ))
    return infos

def build_corpus(repo_root: Path, exclude_rel: str) -> str:
    chunks = []
    for p in repo_root.rglob(f"*{SWIFT_EXT}"):
        rel = str(p.resolve().relative_to(repo_root))
        if rel != exclude_rel:
            chunks.append(read_text(p))
    return "\n".join(chunks)

def count_hits(corpus: str, symbols: List[str]) -> int:
    hits = 0
    for s in symbols:
        hits += len(re.findall(rf'\b{re.escape(s)}\b', corpus))
    return hits

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default="ColorCoded.xcodeproj")
    ap.add_argument("--scheme", default="ColorCoded")
    ap.add_argument("--config", default="Debug")
    ap.add_argument("--src", default="ColorCoded")
    ap.add_argument("--derived", default="/tmp/ccdd")
    ap.add_argument("--buildlog", default="/tmp/cc_build.log")
    args = ap.parse_args()

    repo_root = Path(".").resolve()
    src_root = (repo_root / args.src).resolve()
    if not src_root.exists():
        raise SystemExit(f"Source folder not found: {src_root}")

    run_clean_build(args.project, args.scheme, args.config, args.derived, args.buildlog)
    compiled = extract_compiled_swift_from_buildlog(repo_root, args.buildlog)

    infos = collect_swift_infos(src_root)

    print("\n=== Unused Proof Report (clean-build truth) ===")
    print(f"Observed compiled Swift files: {len(compiled)}")
    if len(compiled) == 0:
        print("NOTE: still 0. Next step: paste `grep -n \"CompileSwift\" /tmp/cc_build.log | head -n 40`.\n")

    order = {"HIGH_CONF_UNUSED": 0, "MAYBE_UNUSED": 1, "USED": 2}
    results: List[Result] = []

    for info in infos:
        corpus = build_corpus(repo_root, info.rel)
        symbols = info.declared_types + info.extended_types
        hits = count_hits(corpus, symbols) if symbols else 0
        is_compiled = info.rel in compiled
        notes: List[str] = []

        if info.has_main:
            verdict = "USED"
            notes.append("@main entrypoint")
        elif (not is_compiled) and hits == 0 and info.declared_types:
            verdict = "HIGH_CONF_UNUSED"
            notes.append("not compiled in clean build")
            notes.append("no symbol references")
        elif not is_compiled:
            verdict = "MAYBE_UNUSED"
            notes.append("not compiled in clean build")
        else:
            verdict = "USED"

        if info.extended_types and not info.declared_types:
            notes.append("extension-only file")

        results.append(Result(info.rel, is_compiled, verdict, hits, notes))

    results.sort(key=lambda r: (order[r.verdict], r.rel))

    for r in results:
        print(f"- {r.rel}")
        print(f"  verdict: {r.verdict}")
        print(f"  compiled: {r.compiled}")
        print(f"  symbol_hits_outside_file: {r.symbol_hits}")
        if r.notes:
            print("  notes:")
            for n in r.notes:
                print(f"    - {n}")
        print()

    if any(r.verdict == "HIGH_CONF_UNUSED" for r in results):
        sys.exit(2)

if __name__ == "__main__":
    main()
