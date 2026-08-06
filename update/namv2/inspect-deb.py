#!/usr/bin/env python3
"""Inspect a prebuilt NAMv2 Debian package and report LV2 integration metadata.

The script deliberately does not guess when multiple plugin/property/port candidates
exist. Use the JSON output to fill config.env before building the UI update package.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

OLD_NAM_URI = "http://github.com/mikeoliphant/neural-amp-modeler-lv2"


def run(*args: str) -> str:
    try:
        result = subprocess.run(
            args,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError as exc:
        raise SystemExit(f"required command not found: {args[0]}") from exc
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip()
        raise SystemExit(f"command failed: {' '.join(args)}\n{stderr}") from exc
    return result.stdout.strip()


def package_field(deb: Path, field: str) -> str:
    return run("dpkg-deb", "-f", str(deb), field)


def read_ttl_files(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for path in sorted(root.rglob("*.ttl")):
        try:
            result[str(path.relative_to(root))] = path.read_text(
                encoding="utf-8", errors="replace"
            )
        except OSError as exc:
            print(f"warning: cannot read {path}: {exc}", file=sys.stderr)
    return result


def unique(values: list[str]) -> list[str]:
    return sorted({value for value in values if value})


def detect_plugin_uris(ttls: dict[str, str]) -> list[str]:
    candidates: list[str] = []
    patterns = (
        r"<([^>]+)>\s+(?:a|rdf:type)\s+[^.]*?lv2:Plugin",
        r"<([^>]+)>\s+(?:a|rdf:type)\s+[^.]*?lv2:AmplifierPlugin",
    )
    for text in ttls.values():
        for pattern in patterns:
            candidates.extend(re.findall(pattern, text, flags=re.DOTALL))
    return unique(candidates)


def detect_model_properties(ttls: dict[str, str]) -> list[str]:
    candidates: list[str] = []
    for text in ttls.values():
        candidates.extend(re.findall(r"patch:writable\s+<([^>]+)>", text))
        candidates.extend(re.findall(r"patch:property\s+<([^>]+)>", text))
        # NAM implementations commonly expose an atom:Path parameter named model.
        for uri in re.findall(r"<([^>]+)>", text):
            lowered = uri.lower()
            if lowered.endswith("#model") or lowered.endswith("/model"):
                candidates.append(uri)
    return unique(candidates)


def detect_ports(ttls: dict[str, str]) -> list[dict[str, Any]]:
    ports: list[dict[str, Any]] = []
    for relpath, text in ttls.items():
        # Inspect all blank nodes containing lv2:symbol. This handles the common
        # `lv2:port [ ... ], [ ... ]` syntax where lv2:port is written once.
        blocks = re.findall(r"\[(.*?)\]", text, flags=re.DOTALL)
        for block in blocks:
            symbol_match = re.search(r'lv2:symbol\s+"([^"]+)"', block)
            if not symbol_match:
                continue
            name_match = re.search(r'lv2:name\s+"([^"]+)"', block)
            classes = unique(re.findall(r"(?:a|rdf:type)\s+([^;.]*)", block))
            ports.append(
                {
                    "file": relpath,
                    "symbol": symbol_match.group(1),
                    "name": name_match.group(1) if name_match else "",
                    "audio": "lv2:AudioPort" in block,
                    "control": "lv2:ControlPort" in block,
                    "atom": "atom:AtomPort" in block,
                    "input": "lv2:InputPort" in block,
                    "output": "lv2:OutputPort" in block,
                    "classes": classes,
                }
            )
    dedup: dict[tuple[Any, ...], dict[str, Any]] = {}
    for port in ports:
        key = (
            port["symbol"],
            port["audio"],
            port["control"],
            port["atom"],
            port["input"],
            port["output"],
        )
        dedup.setdefault(key, port)
    return sorted(dedup.values(), key=lambda item: (item["symbol"], item["file"]))


def choose_single(values: list[str]) -> str | None:
    return values[0] if len(values) == 1 else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("deb", type=Path, help="prebuilt NAMv2 .deb")
    parser.add_argument(
        "--extract-to",
        type=Path,
        help="keep extracted package at this path for manual inspection",
    )
    args = parser.parse_args()

    deb = args.deb.resolve()
    if not deb.is_file():
        parser.error(f"not a file: {deb}")

    temp_dir: tempfile.TemporaryDirectory[str] | None = None
    if args.extract_to:
        extract_root = args.extract_to.resolve()
        if extract_root.exists():
            shutil.rmtree(extract_root)
        extract_root.mkdir(parents=True)
    else:
        temp_dir = tempfile.TemporaryDirectory(prefix="namv2-deb-")
        extract_root = Path(temp_dir.name)

    run("dpkg-deb", "-x", str(deb), str(extract_root))
    ttls = read_ttl_files(extract_root)
    bundles = unique(
        [
            str(path.relative_to(extract_root))
            for path in extract_root.rglob("*.lv2")
            if path.is_dir()
        ]
    )
    binaries = unique(
        [
            str(path.relative_to(extract_root))
            for path in extract_root.rglob("*.so")
            if path.is_file()
        ]
    )
    plugin_uris = detect_plugin_uris(ttls)
    model_properties = detect_model_properties(ttls)
    ports = detect_ports(ttls)

    audio_inputs = [p["symbol"] for p in ports if p["audio"] and p["input"]]
    audio_outputs = [p["symbol"] for p in ports if p["audio"] and p["output"]]
    atom_inputs = [p["symbol"] for p in ports if p["atom"] and p["input"]]
    level_controls = [
        p
        for p in ports
        if p["control"]
        and p["input"]
        and (
            "level" in (p["symbol"] + " " + p["name"]).lower()
            or "gain" in (p["symbol"] + " " + p["name"]).lower()
        )
    ]
    input_levels = [
        p["symbol"]
        for p in level_controls
        if "input" in (p["symbol"] + " " + p["name"]).lower()
        or p["symbol"].lower().startswith("in")
    ]
    output_levels = [
        p["symbol"]
        for p in level_controls
        if "output" in (p["symbol"] + " " + p["name"]).lower()
        or p["symbol"].lower().startswith("out")
    ]

    result: dict[str, Any] = {
        "deb": str(deb),
        "package": package_field(deb, "Package"),
        "version": package_field(deb, "Version"),
        "architecture": package_field(deb, "Architecture"),
        "bundles": bundles,
        "binaries": binaries,
        "ttl_files": sorted(ttls),
        "plugin_uri_candidates": plugin_uris,
        "model_property_uri_candidates": model_properties,
        "ports": ports,
        "suggested": {
            "NAMV2_PLUGIN_URI": choose_single(plugin_uris),
            "NAMV2_MODEL_PROPERTY_URI": choose_single(model_properties),
            "NAMV2_PATCH_PORT_SYMBOL": choose_single(atom_inputs),
            "NAMV2_AUDIO_INPUT_SYMBOL": choose_single(audio_inputs),
            "NAMV2_AUDIO_OUTPUT_SYMBOL": choose_single(audio_outputs),
            "NAMV2_INPUT_LEVEL_SYMBOL": choose_single(input_levels),
            "NAMV2_OUTPUT_LEVEL_SYMBOL": choose_single(output_levels),
        },
        "checks": {
            "plugin_uri_is_distinct_from_existing_nam": bool(plugin_uris)
            and OLD_NAM_URI not in plugin_uris,
            "has_lv2_bundle": bool(bundles),
            "has_shared_object": bool(binaries),
        },
    }

    print(json.dumps(result, indent=2, sort_keys=True))

    if temp_dir is not None:
        temp_dir.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
