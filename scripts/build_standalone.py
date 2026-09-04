#!/usr/bin/env python3
"""Generate the standalone copies of the published artifact pages.

The source is written without <!doctype>/<html>/<head>/<body> because the Artifact
tool supplies that wrapper at publish time. This script adds the same wrapper so the
document opens as a normal file in any browser.

Usage:
    python scripts/build_standalone.py           # write every standalone
    python scripts/build_standalone.py --check   # exit 1 if any is out of date

The standalone is a build output. Never edit it by hand — edit the source and rerun.

WHY THE STANDALONE MATTERS MORE THAN THE HOSTED PAGE. The people who need the PKI
reference are inside the air gap and cannot reach claude.ai at all. The hosted artifact is
for sharing with a program office; the standalone is the copy that works at the rack.
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# One entry per published page. Keep each description identical to the `description`
# passed to the Artifact tool, so the standalone and the hosted page describe themselves
# the same way.
DOCS = [
    {
        "source": ROOT / "artifact" / "artifact-source.html",
        "output": ROOT / "artifact" / "bakeoff-standalone.html",
        "description": (
            "Canonical Kubernetes vs Palette VerteX for a 3-host air-gapped IL5 cluster - "
            "VMware-free architectures and cost breakeven."
        ),
    },
    {
        "source": ROOT / "artifact" / "enclave-pki-source.html",
        "output": ROOT / "artifact" / "enclave-pki-standalone.html",
        "description": (
            "Trust chain, expiry calendar, renewal and recovery for the air-gapped "
            "enclave's internal certificate authority."
        ),
    },
]

# Split point: everything before it is head content, everything after is body content.
BODY_MARKER = '<div class="wrap">'


def render(doc) -> str:
    source, description = doc["source"], doc["description"]
    src = source.read_text(encoding="utf-8")
    try:
        split = src.index(BODY_MARKER)
    except ValueError:
        sys.exit(f"error: {BODY_MARKER!r} not found in {source.name}; cannot split head from body")
    head, body = src[:split].strip(), src[split:].strip()
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="{description}">
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

    rc = 0
    for doc in DOCS:
        source, output = doc["source"], doc["output"]
        if not source.exists():
            print(f"missing source, skipped: {source.relative_to(ROOT).as_posix()}")
            continue
        rendered = render(doc)
        current = output.read_text(encoding="utf-8") if output.exists() else None

        if args.check:
            if current == rendered:
                print(f"up to date: {output.relative_to(ROOT).as_posix()}")
            else:
                print(f"STALE: {output.relative_to(ROOT).as_posix()} does not match "
                      f"{source.relative_to(ROOT).as_posix()} — run python scripts/build_standalone.py")
                rc = 1
            continue

        if current == rendered:
            print(f"unchanged: {output.relative_to(ROOT).as_posix()}")
            continue
        output.write_text(rendered, encoding="utf-8", newline="\n")
        print(f"wrote: {output.relative_to(ROOT).as_posix()} ({len(rendered):,} bytes)")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
