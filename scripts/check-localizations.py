#!/usr/bin/env python3
"""Verifica que cada texto localizable de las apps tenga traducción al español.

Lee las claves que el compilador extrae del código (`*.stringsdata`, SWIFT_EMIT_LOC_STRINGS)
en los builds de verify.sh y las compara con los String Catalogs. También comprueba que los
bundles incluyan `es.lproj`. Falla si no encuentra `.stringsdata`, para no pasar en falso.
"""
import glob
import json
import os
import sys

DERIVED = "build/DerivedData"
TARGETS = {
    # target: (fragmento de ruta de sus intermedios, carpeta de fuentes, bundles construidos)
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
        failures.append(f"{target}: no hay .stringsdata (¿SWIFT_EMIT_LOC_STRINGS?)")
        continue
    for table, table_keys in sorted(keys.items()):
        catalog_path = os.path.join(folder, f"{table}.xcstrings")
        if not os.path.exists(catalog_path):
            failures.append(f"{target}: falta {catalog_path} para {len(table_keys)} claves")
            continue
        with open(catalog_path, encoding="utf-8") as f:
            catalog = json.load(f)
        missing = sorted(k for k in table_keys if not translated(catalog, k))
        for key in missing:
            failures.append(f"{target}: sin traducción al español en {table}: {key!r}")
        print(f"    {target}/{table}: {len(table_keys)} claves, {len(missing)} sin traducir")
    for bundle in bundles:
        for name in ("Localizable.strings", "InfoPlist.strings"):
            path = f"{DERIVED}/Build/Products/{bundle}/es.lproj/{name}"
            if not os.path.exists(path):
                failures.append(f"{target}: falta {path}")

if failures:
    print("\n".join(f"ERROR: {f}" for f in failures), file=sys.stderr)
    sys.exit(1)
