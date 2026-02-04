#!/usr/bin/env python3
import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

# -------------------------
# Utilities
# -------------------------

SWIFT_EXT = ".swift"

PBX_TARGET_NAME_RE = re.compile(r'/\* (.*?) \*/ = \{')
PBX_OBJECT_HEADER_RE = re.compile(r'([A-F0-9]{24}) /\* (.*?) \*/ = \{')
PBX_ISA_RE = re.compile(r'\bisa\s*=\s*(\w+)\s*;')
PBX_NAME_RE = re.compile(r'\bname\s*=\s*(.*?)\s*;')
PBX_BUILD_PHASES_RE = re.compile(r'\bbuildPhases\s*=\s*\((.*?)\);', re.S)
PBX_FILES_RE = re.compile(r'\bfiles\s*=\s*\((.*?)\);', re.S)

PBX_BUILD_FILE_REF_RE = re.compile(r'([A-F0-9]{24}) /\* (.*?) \*/')
PBX_FILE_REF_PATH_RE = re.compile(r'\bpath\s*=\s*(.*?)\s*;')
PBX_FILE_REF_NAME_RE = re.compile(r'\bname\s*=\s*(.*?)\s*;')

SWIFT_TYPE_DECL_RE = re.compile(r'^\s*(public\s+|internal\s+|fileprivate\s+|private\s+)?(final\s+)?(class|struct|enum|actor|protocol)\s+([A-Za-z_]\w*)', re.M)

# function decls are harder; we rely on top-level type names primarily
# but optionally include "static func foo" signatures for enums/structs
SWIFT_STATIC_FUNC_RE = re.compile(r'^\s*static\s+func\s+([A-Za-z_]\w*)\s*\(', re.M)

# ignore references inside the file itself when searching repo usage
def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""

def strip_quotes(s: str) -> str:
    s = s.strip()
    if s.startswith('"') and s.endswith('"'):
        return s[1:-1]
    return s

def pbx_unescape(s: str) -> str:
    # pbxproj uses quoted strings for paths; keep it simple
    return strip_quotes(s)

@dataclass
class SwiftFileInfo:
    rel_path: str
    abs_path: Path
    declared_types: List[str]
    declared_static_funcs: List[str]

@dataclass
class TargetCompileInfo:
    target_name: str
    swift_files_in_compile_sources: Set[str]  # rel paths, normalized

# -------------------------
# PBXProj parsing (best-effort)
# -------------------------

def parse_pbx_objects(pbx_text: str) -> Dict[str, Dict]:
    """
    Very lightweight PBXProj object parser:
    Extracts objects keyed by 24-hex ID; captures isa, name/path fields, and some lists.
    This is not a full parser, but good enough for:
      - PBXNativeTarget build phases
      - PBXSourcesBuildPhase files
      - PBXBuildFile fileRef
      - PBXFileReference path/name
    """
    objects: Dict[str, Dict] = {}
    # Narrow to objects section if possible
    # (pbxproj has 'objects = { ... };')
    m = re.search(r'objects\s*=\s*\{(.*)\};\s*/\* End PBXProject section \*/', pbx_text, re.S)
    obj_block = m.group(1) if m else pbx_text

    # Split by object headers (ID /* name */ = { ... };)
    # We'll iterate using regex finditer and slice.
    headers = list(PBX_OBJECT_HEADER_RE.finditer(obj_block))
    for i, h in enumerate(headers):
        obj_id = h.group(1)
        start = h.end()
        end = headers[i+1].start() if i+1 < len(headers) else len(obj_block)
        chunk = obj_block[start:end]

        isa = PBX_ISA_RE.search(chunk)
        isa_val = isa.group(1) if isa else None

        # capture name/path if present
        name_m = PBX_NAME_RE.search(chunk)
        name_val = pbx_unescape(name_m.group(1)) if name_m else None
        path_m = PBX_FILE_REF_PATH_RE.search(chunk)
        path_val = pbx_unescape(path_m.group(1)) if path_m else None

        # capture buildPhases list
        bp_m = PBX_BUILD_PHASES_RE.search(chunk)
        build_phases: List[str] = []
        if bp_m:
            inner = bp_m.group(1)
            build_phases = [x.strip().split()[0] for x in inner.split(",") if x.strip()]
            # fix entries that look like "ABC /* foo */"
            build_phases = [re.match(r'([A-F0-9]{24})', x).group(1) for x in build_phases if re.match(r'[A-F0-9]{24}', x)]

        # capture files list
        files_m = PBX_FILES_RE.search(chunk)
        files_list: List[str] = []
        if files_m:
            inner = files_m.group(1)
            # entries look like: ABCDEF... /* file.swift in Sources */,
            for mm in PBX_BUILD_FILE_REF_RE.finditer(inner):
                files_list.append(mm.group(1))

        objects[obj_id] = {
            "isa": isa_val,
            "name": name_val,
            "path": path_val,
            "buildPhases": build_phases,
            "files": files_list,
            "raw": chunk,
        }
    return objects

def find_native_target(objects: Dict[str, Dict], target_name: str) -> Optional[str]:
    for obj_id, obj in objects.items():
        if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == target_name:
            return obj_id
    return None

def find_sources_build_phase(objects: Dict[str, Dict], phase_ids: List[str]) -> Optional[str]:
    for pid in phase_ids:
        obj = objects.get(pid)
        if not obj:
            continue
        if obj.get("isa") == "PBXSourcesBuildPhase":
            return pid
    return None

def resolve_buildfile_to_filereference(objects: Dict[str, Dict], buildfile_id: str) -> Optional[str]:
    obj = objects.get(buildfile_id)
    if not obj:
        return None
    # build file contains 'fileRef = XXXXX /* Foo.swift */;'
    m = re.search(r'\bfileRef\s*=\s*([A-F0-9]{24})\b', obj.get("raw",""))
    return m.group(1) if m else None

def resolve_filereference_path(objects: Dict[str, Dict], fileref_id: str) -> Optional[str]:
    obj = objects.get(fileref_id)
    if not obj:
        return None
    # Prefer path; fallback to name
    path = obj.get("path") or obj.get("name")
    return path

def collect_compile_sources_swift_files(pbxproj_path: Path, src_root: Path, target_name: str) -> TargetCompileInfo:
    pbx_text = read_text(pbxproj_path)
    objects = parse_pbx_objects(pbx_text)

    target_id = find_native_target(objects, target_name)
    if not target_id:
        raise SystemExit(f"ERROR: Could not find PBXNativeTarget named '{target_name}' in {pbxproj_path}")

    phase_ids = objects[target_id].get("buildPhases", [])
    sources_phase_id = find_sources_build_phase(objects, phase_ids)
    if not sources_phase_id:
        raise SystemExit(f"ERROR: Could not find PBXSourcesBuildPhase for target '{target_name}'")

    buildfile_ids = objects[sources_phase_id].get("files", [])
    swift_files: Set[str] = set()

    for bf_id in buildfile_ids:
        fileref_id = resolve_buildfile_to_filereference(objects, bf_id)
        if not fileref_id:
            continue
        rel = resolve_filereference_path(objects, fileref_id)
        if not rel:
            continue
        rel = rel.strip()
        if rel.endswith(SWIFT_EXT):
            # Normalize: sometimes path is just "Foo.swift" not "ColorCoded/Foo.swift"
            # We'll try to locate it under src_root
            # We'll store relative to repo root
            # find by name if needed
            candidate = (src_root / rel)
            if candidate.exists():
                swift_files.add(str(candidate.relative_to(src_root.parent)))
            else:
                # search by filename under src_root
                matches = list(src_root.rglob(Path(rel).name))
                if len(matches) == 1:
                    swift_files.add(str(matches[0].relative_to(src_root.parent)))
                elif len(matches) > 1:
                    # ambiguous; store raw
                    swift_files.add(rel)

    return TargetCompileInfo(target_name=target_name, swift_files_in_compile_sources=swift_files)

# -------------------------
# Swift scanning
# -------------------------

def collect_repo_swift_files(src_root: Path) -> List[SwiftFileInfo]:
    infos: List[SwiftFileInfo] = []
    for p in sorted(src_root.rglob(f"*{SWIFT_EXT}")):
        text = read_text(p)
        types = [m.group(4) for m in SWIFT_TYPE_DECL_RE.finditer(text)]
        funcs = [m.group(1) for m in SWIFT_STATIC_FUNC_RE.finditer(text)]
        infos.append(SwiftFileInfo(
            rel_path=str(p.relative_to(src_root.parent)),
            abs_path=p,
            declared_types=sorted(set(types)),
            declared_static_funcs=sorted(set(funcs)),
        ))
    return infos

def build_code_corpus(repo_root: Path, exclude_paths: Set[str]) -> str:
    """
    Concatenate all swift file content into one big string for fast grep.
    exclude_paths are rel paths to skip (like the file itself when checking usage).
    """
    chunks = []
    for p in repo_root.rglob(f"*{SWIFT_EXT}"):
        rel = str(p.relative_to(repo_root))
        if rel in exclude_paths:
            continue
        chunks.append(read_text(p))
    return "\n".join(chunks)

def count_symbol_hits(corpus: str, symbol: str) -> int:
    # Word boundary helps reduce false positives
    pattern = re.compile(rf'\b{re.escape(symbol)}\b')
    return len(pattern.findall(corpus))

# -------------------------
# Report logic
# -------------------------

@dataclass
class FileUsageResult:
    rel_path: str
    in_compile_sources: bool
    declared_types: List[str]
    declared_static_funcs: List[str]
    type_hits: Dict[str, int]
    verdict: str  # "USED" | "MAYBE_UNUSED" | "HIGH_CONF_UNUSED"
    notes: List[str]

def analyze_usage(repo_root: Path, src_root: Path, compile_info: TargetCompileInfo) -> List[FileUsageResult]:
    swift_infos = collect_repo_swift_files(src_root)

    results: List[FileUsageResult] = []

    for info in swift_infos:
        in_sources = info.rel_path in compile_info.swift_files_in_compile_sources

        # Build corpus excluding this file itself
        corpus = build_code_corpus(repo_root, exclude_paths={info.rel_path})

        hits: Dict[str, int] = {}
        total_hits = 0
        for t in info.declared_types:
            h = count_symbol_hits(corpus, t)
            hits[t] = h
            total_hits += h

        notes: List[str] = []

        # Heuristics
        if not info.declared_types:
            notes.append("No top-level type declarations found (file may contain only extensions/functions).")

        if not in_sources:
            notes.append("Not listed in target Compile Sources (per pbxproj).")

        if total_hits == 0:
            notes.append("No references to declared top-level types found outside this file.")

        # Verdict determination
        if (not in_sources) and (total_hits == 0):
            verdict = "HIGH_CONF_UNUSED"
        elif total_hits == 0:
            # Might still be used via extensions, operators, stringly-typed selectors, etc.
            verdict = "MAYBE_UNUSED"
        else:
            verdict = "USED"

        results.append(FileUsageResult(
            rel_path=info.rel_path,
            in_compile_sources=in_sources,
            declared_types=info.declared_types,
            declared_static_funcs=info.declared_static_funcs,
            type_hits=hits,
            verdict=verdict,
            notes=notes
        ))

    return results

def print_report(results: List[FileUsageResult]) -> None:
    # Sort by verdict severity, then by in_compile_sources false first, then by name
    order = {"HIGH_CONF_UNUSED": 0, "MAYBE_UNUSED": 1, "USED": 2}
    results = sorted(results, key=lambda r: (order.get(r.verdict, 9), r.in_compile_sources, r.rel_path))

    print("\n=== Unused Proof Report ===\n")
    for r in results:
        print(f"- {r.rel_path}")
        print(f"  verdict: {r.verdict}")
        print(f"  in_compile_sources: {r.in_compile_sources}")
        if r.declared_types:
            print(f"  declared_types: {', '.join(r.declared_types)}")
            # show top 5 hit counts
            top = sorted(r.type_hits.items(), key=lambda kv: kv[1], reverse=True)
            top = [kv for kv in top if kv[1] > 0][:5]
            if top:
                print("  references:")
                for sym, cnt in top:
                    print(f"    - {sym}: {cnt}")
            else:
                print("  references: none")
        else:
            print("  declared_types: (none detected)")
        if r.notes:
            print("  notes:")
            for n in r.notes:
                print(f"    - {n}")
        print()

def main():
    ap = argparse.ArgumentParser(description="Locate & prove unused Swift files (pbxproj + symbol reachability).")
    ap.add_argument("--project", required=True, help="Path to project.pbxproj")
    ap.add_argument("--src", required=True, help="Source root folder (e.g. ColorCoded)")
    ap.add_argument("--target", required=True, help="Xcode target name (e.g. ColorCoded)")
    args = ap.parse_args()

    pbxproj_path = Path(args.project).resolve()
    src_root = Path(args.src).resolve()
    repo_root = src_root.parent

    if not pbxproj_path.exists():
        raise SystemExit(f"ERROR: project not found: {pbxproj_path}")
    if not src_root.exists():
        raise SystemExit(f"ERROR: src root not found: {src_root}")

    compile_info = collect_compile_sources_swift_files(pbxproj_path, src_root, args.target)
    results = analyze_usage(repo_root, src_root, compile_info)
    print_report(results)

    # Exit code: non-zero if any high-confidence unused
    unused = [r for r in results if r.verdict == "HIGH_CONF_UNUSED"]
    if unused:
        sys.exit(2)

if __name__ == "__main__":
    main()
