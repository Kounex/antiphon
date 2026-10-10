#!/usr/bin/env python3
"""Generates the AntiphonDesign color asset catalog from design/design-system/tokens.json.

Run from the repo root:  python3 scripts/generate_color_assets.py
Every color token becomes a .colorset with light ("any") and dark appearances.
Web-only preview tokens (glass-*) are skipped: SwiftUI draws real glass.

Increase Contrast: tokens.json defines no high-contrast values, so a few
tokens get derived ones (marked DERIVED below) so text and separators hold
up when the setting is on.
"""
import json, os, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKENS = os.path.join(ROOT, "design/design-system/tokens.json")
OUT = os.path.join(ROOT, "Packages/AntiphonDesign/Sources/AntiphonDesign/Resources/Colors.xcassets")
SKIP = {"glass-fill", "glass-fill-clear", "glass-rim"}

def parse(hex_):
    h = hex_.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    a = int(h[6:8], 16) / 255 if len(h) == 8 else 1.0
    return {"red": f"{r:.3f}", "green": f"{g:.3f}", "blue": f"{b:.3f}", "alpha": f"{a:.3f}"}

def color(components):
    return {"color": {"color-space": "srgb", "components": components}}

def with_alpha(c, factor):
    c = dict(c); c["alpha"] = f"{min(1.0, float(c['alpha']) * factor):.3f}"; return c

def main():
    tokens = {t["name"]: t["value"] for t in json.load(open(TOKENS))["color"]["tokens"]}
    def resolve(v):
        if isinstance(v, str) and v.startswith("{"):
            return resolve(tokens[v.strip("{}")])
        return v if isinstance(v, dict) else {"light": v, "dark": v}

    values = {name: resolve(v) for name, v in tokens.items() if name not in SKIP}
    # DERIVED high-contrast values: muted text reads as primary, faint as muted,
    # separators get 2.5x the opacity.
    high_contrast = {
        "ink-muted": values["ink"],
        "ink-faint": values["ink-muted"],
        "status-missing": values["ink"],
    }

    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(OUT, "Contents.json"), "w"), indent=2)

    for name, v in sorted(values.items()):
        light, dark = parse(v["light"]), parse(v["dark"])
        entries = [
            {"idiom": "universal", **color(light)},
            {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}], **color(dark)},
        ]
        hc = high_contrast.get(name)
        if name == "hairline":
            hc_light, hc_dark = with_alpha(light, 2.5), with_alpha(dark, 2.5)
        elif hc:
            hc_light, hc_dark = parse(hc["light"]), parse(hc["dark"])
        else:
            hc_light = hc_dark = None
        if hc_light:
            contrast = {"appearance": "contrast", "value": "high"}
            entries += [
                {"idiom": "universal", "appearances": [contrast], **color(hc_light)},
                {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}, contrast], **color(hc_dark)},
            ]
        d = os.path.join(OUT, f"{name}.colorset")
        os.makedirs(d)
        json.dump({"colors": entries, "info": {"author": "xcode", "version": 1}}, open(os.path.join(d, "Contents.json"), "w"), indent=2)
    print(f"Wrote {len(values)} color sets to {os.path.relpath(OUT, ROOT)}")

if __name__ == "__main__":
    sys.exit(main())
