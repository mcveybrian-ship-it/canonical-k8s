#!/usr/bin/env python3
"""Generate artifact/bakeoff-standalone.html from artifact/artifact-source.html.

The source is written without <!doctype>/<html>/<head>/<body> because the Artifact
tool supplies that wrapper at publish time. This script adds the same wrapper so the
document opens as a normal file in any browser.

Usage:
    python scripts/build_standalone.py           # write the standalone
    python scripts/build_standalone.py --check   # exit 1 if it is out of date

The standalone is a build output. Never edit it by hand — edit the source and rerun.
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "artifact" / "artifact-source.html"
OUTPUT = ROOT / "artifact" / "bakeoff-standalone.html"

# Split point: everything before it is head content, everything after is body content.
BODY_MARKER = '<div class="wrap">'

# The <meta name="description"> for the standalone file. Keep this identical to the
# `description` passed to the Artifact tool when republishing, so the standalone and the
# hosted page describe themselves the same way.
DESCRIPTION = (
    "Canonical Kubernetes vs Palette VerteX for a 3-host air-gapped IL5 cluster - "
    "VMware-free architectures and cost breakeven."
)


def render() -> str:
    src = SOURCE.read_text(encoding="utf-8")
    try:
        split = src.index(BODY_MARKER)
    except ValueError:
        sys.exit(f"error: {BODY_MARKER!r} not found in {SOURCE.name}; cannot split head from body")
    head, body = src[:split].strip(), src[split:].strip()
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="{DESCRIPTION}">
{head}
</head>
<body>
{body}
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="verify the standalone is current instead of writing it")
    args = parser.parse_args()

    rendered = render()
    current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else None

    if args.check:
        if current == rendered:
            print(f"up to date: {OUTPUT.relative_to(ROOT).as_posix()}")
            return 0
        print(f"STALE: {OUTPUT.relative_to(ROOT).as_posix()} does not match "
              f"{SOURCE.relative_to(ROOT).as_posix()} — run python scripts/build_standalone.py")
        return 1

    if current == rendered:
        print(f"unchanged: {OUTPUT.relative_to(ROOT).as_posix()}")
        return 0

    OUTPUT.write_text(rendered, encoding="utf-8", newline="\n")
    print(f"wrote: {OUTPUT.relative_to(ROOT).as_posix()} ({len(rendered):,} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
