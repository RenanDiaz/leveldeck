#!/usr/bin/env python3
"""Verifies that every localizable string in the apps has a Spanish translation.

Reads the keys the compiler extracts from the code (`*.stringsdata`, SWIFT_EMIT_LOC_STRINGS)
in verify.sh's builds and compares them with the String Catalogs. Also checks that the
bundles include `es.lproj`. Fails if it finds no `.stringsdata`, so it can't pass falsely.
"""
import glob
import json
import os
import sys

DERIVED = "build/DerivedData"
TARGETS = {
    # target: (path fragment of its intermediates, source folder, built bundles)
    "LevelDeck": (
        "-iphonesimulator/LevelDeck.build/",
        "LevelDeck",
        ["Debug-iphonesimulator/LevelDeck.app", "Release-iphonesimulator/LevelDeck.app"],
    ),
    "LevelDeckAgent": (
        "/LevelDeckAgent.build/",
        "LevelDeckAgent",
        ["Debug/LevelDeckAgent.app/Contents/Resources", "Release/LevelDeckAgent.app/Contents/Resources"],
    ),
}


def extracted_keys(fragment):
    paths = [p for p in glob.glob(f"{DERIVED}/Build/Intermediates.noindex/**/*.stringsdata", recursive=True)
             if fragment in p]
    keys = {}
    for path in paths:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        for table, entries in data.get("tables", {}).items():
            for entry in entries:
                keys.setdefault(table, set()).add(entry["key"])
    return paths, keys


def translated(catalog, key):
    es = catalog.get("strings", {}).get(key, {}).get("localizations", {}).get("es", {})
    return es.get("stringUnit", {}).get("state") == "translated" or "variations" in es


failures = []
for target, (fragment, folder, bundles) in TARGETS.items():
    paths, keys = extracted_keys(fragment)
    if not paths:
        failures.append(f"{target}: no .stringsdata found (SWIFT_EMIT_LOC_STRINGS?)")
        continue
    for table, table_keys in sorted(keys.items()):
        catalog_path = os.path.join(folder, f"{table}.xcstrings")
        if not os.path.exists(catalog_path):
            failures.append(f"{target}: missing {catalog_path} for {len(table_keys)} keys")
            continue
        with open(catalog_path, encoding="utf-8") as f:
            catalog = json.load(f)
        missing = sorted(k for k in table_keys if not translated(catalog, k))
        for key in missing:
            failures.append(f"{target}: no Spanish translation in {table}: {key!r}")
        print(f"    {target}/{table}: {len(table_keys)} keys, {len(missing)} untranslated")
    for bundle in bundles:
        for name in ("Localizable.strings", "InfoPlist.strings"):
            path = f"{DERIVED}/Build/Products/{bundle}/es.lproj/{name}"
            if not os.path.exists(path):
                failures.append(f"{target}: missing {path}")

if failures:
    print("\n".join(f"ERROR: {f}" for f in failures), file=sys.stderr)
    sys.exit(1)
