#!/usr/bin/env python3
"""
cci-coverage.py - map the enclave's STIG/SRG set onto NIST 800-53 Rev 5, and name the gap.

    MACHINE: stage-01 (wherever the DISA downloads are).

    ./scripts/cci-coverage.py --stigs docs/compliance/stigs
    ./scripts/cci-coverage.py --stigs docs/compliance/stigs --json out.json

WHY THIS EXISTS
---------------
The question "which 800-53 controls does our STIG work actually evidence, and which does it
not touch at all" has a mechanical answer, and it is the only part of an SSP that does. Every
STIG rule carries CCI identifiers; the CCI List maps each CCI to 800-53 control references.
So STIG -> CCI -> control is a JOIN, not a judgement, and it should never be done by hand.

What is NOT mechanical, and is deliberately left to a person:
  * WHICH documents apply to this system (the applicability determination)
  * whether a control the STIGs do not cover is satisfied some other way
  * the authorising official's baseline and overlay set

So this tool reports coverage and gaps. It does not decide anything.

A NOTE ON WHAT "COVERED" MEANS HERE
-----------------------------------
"Covered" means: at least one rule in the assessed document set cites a CCI that maps to that
control. It does NOT mean the control is satisfied - a rule can be Open. Coverage is about
whether the control is in scope of automated assessment at all. Satisfaction is a separate
question answered by the scan results, and conflating the two is how a checklist gets read as
an authorisation.
"""
import argparse, collections, glob, json, os, re, sys
import xml.etree.ElementTree as ET

# A control id, normalised. "AC-1 a 1 (a)" is a PART of AC-1, not a separate control, but
# "AC-2 (1)" is a distinct enhancement and must stay distinct. Parts are lower-case letters
# and bare digits; an enhancement is a parenthesised number IMMEDIATELY after the number.
CTRL = re.compile(r'^([A-Z]{2})-(\d+)(?:\s*\((\d+)\))?')


def normalise(ref: str):
    m = CTRL.match(ref.strip())
    if not m:
        return None
    fam, num, enh = m.group(1), m.group(2), m.group(3)
    return f"{fam}-{num}({enh})" if enh else f"{fam}-{num}"


def load_cci_map(path, revision="NIST SP 800-53 Revision 5"):
    """CCI-000001 -> {'AC-1', 'AC-2(1)', ...} for one revision."""
    tree = ET.parse(path)
    out = {}
    for item in tree.iter():
        if not item.tag.endswith('}cci_item'):
            continue
        cci = item.get('id')
        if not cci:
            continue
        ctrls = set()
        for ref in item.iter():
            if ref.tag.endswith('}reference') and ref.get('title') == revision:
                idx = ref.get('index') or (ref.text or '')
                c = normalise(idx)
                if c:
                    ctrls.add(c)
        if ctrls:
            out[cci] = ctrls
    return out


def rules_and_ccis(xccdf):
    """[(vid, title, severity, {CCI-...}), ...] for one XCCDF."""
    tree = ET.parse(xccdf)
    rules = []
    for r in tree.iter():
        if not r.tag.endswith('}Rule'):
            continue
        vid = r.get('id', '?')
        sev = r.get('severity', 'unknown')
        title = ''
        ccis = set()
        for e in r.iter():
            tag = e.tag.split('}')[-1]
            if tag == 'title' and e.text and not title:
                title = e.text.strip()
            elif tag == 'ident' and e.text and e.text.startswith('CCI-'):
                ccis.add(e.text.strip())
        rules.append((vid, title, sev, ccis))
    return rules


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stigs', default='docs/compliance/stigs',
                    help='directory holding the DISA zips, or their extracted form')
    ap.add_argument('--extracted', default=None,
                    help='directory of already-extracted XCCDFs (skips unzipping)')
    ap.add_argument('--json', default=None, help='write the full result as JSON')
    ap.add_argument('--revision', default='NIST SP 800-53 Revision 5')
    args = ap.parse_args()

    root = args.extracted or args.stigs
    xccdfs = sorted(set(
        glob.glob(os.path.join(root, '**', '*xccdf*.xml'), recursive=True) +
        glob.glob(os.path.join(root, '**', '*Benchmark*.xml'), recursive=True)))
    cci_files = glob.glob(os.path.join(root, '**', 'CCI_List.xml'), recursive=True)

    if not cci_files:
        sys.exit("no CCI_List.xml under %s - it is the join key; nothing can be mapped "
                 "without it" % root)
    if not xccdfs:
        sys.exit("no XCCDF documents under %s" % root)

    cci_map = load_cci_map(cci_files[0], args.revision)

    print("\n  CCI -> %s" % args.revision)
    print("    %d CCIs carry a mapping\n" % len(cci_map))

    per_doc = {}
    unmapped_ccis = collections.Counter()
    for x in xccdfs:
        name = os.path.basename(x).replace('_Manual-xccdf.xml', '').replace('.xml', '')
        rules = rules_and_ccis(x)
        ctrls, no_cci = set(), 0
        for vid, title, sev, ccis in rules:
            if not ccis:
                no_cci += 1
            for c in ccis:
                if c in cci_map:
                    ctrls |= cci_map[c]
                else:
                    unmapped_ccis[c] += 1
        per_doc[name] = {'path': x, 'rules': len(rules), 'rules_without_cci': no_cci,
                         'controls': sorted(ctrls)}

    print("  PER DOCUMENT - rules, and the 800-53 controls they touch\n")
    print("    %-48s %6s %8s %s" % ("document", "rules", "no-CCI", "controls"))
    for name, d in sorted(per_doc.items()):
        print("    %-48s %6d %8d %d" % (name[:48], d['rules'], d['rules_without_cci'],
                                        len(d['controls'])))

    union = set()
    for d in per_doc.values():
        union |= set(d['controls'])
    universe = set()
    for cs in cci_map.values():
        universe |= cs

    gap = universe - union
    print("\n  TOTALS")
    print("    controls touched by this document set : %d" % len(union))
    print("    controls the CCI List references at all: %d" % len(universe))
    print("    NOT touched by any document here       : %d" % len(gap))

    if unmapped_ccis:
        print("\n  [!] %d distinct CCIs cited by these documents have NO %s mapping."
              % (len(unmapped_ccis), args.revision))
        print("      Most likely Rev-4-only CCIs. They are NOT silently dropped - listed here:")
        for c, n in unmapped_ccis.most_common(10):
            print("        %s  (cited %d times)" % (c, n))

    fam = collections.Counter(c.split('-')[0] for c in gap)
    print("\n  THE GAP, BY FAMILY - controls no rule in this set touches")
    print("  These cannot be evidenced by scanning. Each needs a documented answer.\n")
    for f, n in sorted(fam.items()):
        print("    %-6s %3d" % (f, n))

    if args.json:
        with open(args.json, 'w') as fh:
            json.dump({'revision': args.revision,
                       'per_document': per_doc,
                       'covered': sorted(union),
                       'universe': sorted(universe),
                       'gap': sorted(gap),
                       'unmapped_ccis': dict(unmapped_ccis)}, fh, indent=2)
        print("\n  wrote %s" % args.json)
    print()


if __name__ == '__main__':
    main()
