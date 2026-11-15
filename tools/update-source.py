#!/usr/bin/env python3
"""Añade (o sustituye) una versión de Fretline en la fuente de SideStore/AltStore.

Lee la versión, el número de build, el iOS mínimo y los permisos de privacidad
directamente del Info.plist del .ipa, para que la fuente siempre coincida con la app
(AltStore/SideStore rechazan instalar si los permisos no coinciden).

Uso:
  python3 tools/update-source.py --ipa dist/Fretline-0.3.0.ipa
"""
import argparse
import datetime as dt
import json
import os
import plistlib
import re
import sys
import zipfile


def read_info_plist(ipa_path):
    with zipfile.ZipFile(ipa_path) as z:
        names = [n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if not names:
            sys.exit(f"❌ No se encontró Payload/*.app/Info.plist dentro de {ipa_path}")
        return plistlib.loads(z.read(names[0]))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--ipa", required=True, help="ruta del .ipa publicado en la release")
    p.add_argument("--json", default="docs/apps.json", help="fuente a actualizar")
    p.add_argument("--repo", default="rbc33/Fretline", help="repo de GitHub con las releases")
    p.add_argument("--notes", default=None, help="novedades de la versión")
    args = p.parse_args()

    info = read_info_plist(args.ipa)
    version = info["CFBundleShortVersionString"]
    build = str(info["CFBundleVersion"])
    bundle_id = info["CFBundleIdentifier"]
    min_os = info.get("MinimumOSVersion")
    privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}

    with open(args.json, encoding="utf-8") as f:
        source = json.load(f)

    app = next((a for a in source["apps"] if a["bundleIdentifier"] == bundle_id), None)
    if app is None:
        sys.exit(f"❌ La fuente no tiene ninguna app con bundleIdentifier {bundle_id}")

    file_name = os.path.basename(args.ipa)
    entry = {
        "version": version,
        "buildVersion": build,
        "date": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
        "localizedDescription": args.notes
        or f"Fretline {version}. Full release notes: https://github.com/{args.repo}/releases/tag/v{version}",
        "downloadURL": f"https://github.com/{args.repo}/releases/download/v{version}/{file_name}",
        "size": os.path.getsize(args.ipa),
    }
    if min_os:
        entry["minOSVersion"] = min_os

    # La más reciente va primero; si se rehace una versión (--replace), se sustituye
    app["versions"] = [entry] + [v for v in app.get("versions", []) if v.get("version") != version]
    app.setdefault("appPermissions", {})["privacy"] = privacy
    app["appPermissions"].setdefault("entitlements", [])

    with open(args.json, "w", encoding="utf-8") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"✅ {args.json}: Fretline {version} ({build}), {entry['size']} bytes, permisos {sorted(privacy) or 'ninguno'}")


if __name__ == "__main__":
    main()
