#!/usr/bin/env python3
"""
asd-triage.py - turn 286 Application Security & Development STIG rules into ~a dozen decisions.

    MACHINE: stage-01 (wherever the DISA downloads are).

    ./scripts/asd-triage.py --xccdf <path to U_ASD_STIG_V6R4_Manual-xccdf.xml>
    ./scripts/asd-triage.py --xccdf <path> --json asd.json --md docs/compliance/asd-triage.md

WHY THIS EXISTS
---------------
The ASD STIG has to be COMPLETED, not excluded - every row needs a defensible rationale even
when most end up Not Applicable. Answering 286 rows by hand produces 286 slightly different
wordings, and an assessor reads the inconsistency before the content.

WHAT IT WILL NOT DO, DELIBERATELY
---------------------------------
It does not write rationales and it does not decide applicability. Both would fail review:

  * A rationale that PARAPHRASES DISA's check text is weaker than one that quotes it. This
    tool extracts the exact sentence and hands it over verbatim.
  * Applicability depends on facts about THIS system that are nowhere in the XCCDF. Only a
    person knows whether the application provides interactive user access, because there is
    no application yet.

So it groups, quotes, and counts. The judgement stays with the assessor, and what the tool
emits is traceable to DISA's own words.

THE GROUPING THAT MATTERS
-------------------------
Not keyword themes - the document's OWN conditions. 139 of 286 rules carry a clause of the
form "If the application does not X, this is not applicable", and those conditions REPEAT.
Normalising and clustering them turns the N/A half into a handful of yes/no questions:
answer "does the application provide an interface for interactive user access?" once, and
every rule carrying that condition is answered.

Rules with no N/A clause are grouped by SRG family instead, because that is the next most
honest axis the document supplies.
"""
import argparse, collections, json, os, re, sys
import xml.etree.ElementTree as ET

NS = lambda e: e.tag.split('}')[-1]

# The sentence that offers an exemption. DISA writes these in a few shapes; catch them all,
# then normalise for clustering.
NA_SENT = re.compile(
    r'((?:^|(?<=[.!?]))\s*[^.!?]*?\bnot applicable\b[^.!?]*[.!?])', re.I | re.S)


def normalise_condition(sent: str) -> str:
    """Collapse a condition to a clustering key. Lower, strip filler, squeeze whitespace."""
    s = ' '.join(sent.split()).lower()
    s = re.sub(r'^(if|when)\s+', '', s)
    s = re.sub(r',?\s*(this (requirement )?is )?not applicable\.?$', '', s)
    s = re.sub(r'\b(the )?application\b', 'application', s)
    s = re.sub(r'[^a-z0-9 ]+', '', s)
    return ' '.join(s.split())


def parse(path):
    tree = ET.parse(path)
    out = []
    for g in tree.iter():
        if not NS(g) == 'Group':
            continue
        vid = g.get('id', '')
        rec = {'vid': vid, 'stig_id': '', 'severity': '?', 'title': '',
               'check': '', 'fix': '', 'ccis': []}
        for e in g.iter():
            tag = NS(e)
            if tag == 'Rule':
                rec['severity'] = e.get('severity', '?')
                # The RULE's title is the requirement. The GROUP's title is boilerplate
                # ("DPMS Target Application Security and Development") and using it makes
                # every row look identical - which is how a 286-row checklist becomes
                # unreadable.
                for sub in e:
                    if NS(sub) == 'title' and sub.text:
                        rec['title'] = ' '.join(sub.text.split())
                        break
            elif tag == 'version' and e.text and not rec['stig_id']:
                rec['stig_id'] = e.text.strip()
            elif tag == 'check-content' and e.text:
                rec['check'] = ' '.join(e.text.split())
            elif tag == 'fixtext' and e.text:
                rec['fix'] = ' '.join(e.text.split())
            elif tag == 'ident' and e.text and e.text.startswith('CCI-'):
                rec['ccis'].append(e.text.strip())
        m = NA_SENT.search(rec['check'])
        rec['na_clause'] = m.group(1).strip() if m else ''
        rec['na_key'] = normalise_condition(rec['na_clause']) if rec['na_clause'] else ''
        out.append(rec)
    return out


# THE PROPERTY THE CONDITION IS ASKING ABOUT.
#
# Clustering on the whole sentence over-splits: "not PK-enabled" and "not PKI-enabled" are the
# same question, and so are "development is not done in house" and "development is not managed
# by the organization". Clustering too loosely is worse - it answers two different questions
# with one rationale, which is exactly what an assessor pulls on.
#
# So this extracts the PREDICATE - what the application does or does not do - and leaves the
# full sentence attached to every rule. The reviewer answers a property once; the rationale
# still quotes each rule's own words.
PROP = re.compile(
    r'\bapplication\s+(?:is\s+not|does\s+not|is|does|uses|utilizes|utilises|provides)\s+(.{4,70}?)'
    r'(?:\s+(?:the\s+)?(?:requirement|check|this)\b|$)', re.I)

def property_of(key: str) -> str:
    """A short label for the thing being asked about, for grouping questions."""
    if not key:
        return ''
    m = PROP.search(key)
    frag = (m.group(1) if m else key).strip()
    frag = re.sub(r'^(provide|use|utilize|utilise|contain|implement|have)\s+', '', frag)
    frag = re.sub(r'\b(a|an|the|its own|any)\b', ' ', frag)
    frag = re.sub(r'\bpk\s*enabled\b', 'pki enabled', frag)
    return ' '.join(frag.split())[:60]


def srg_family(stig_id: str) -> str:
    m = re.match(r'([A-Z]+-[A-Z]+)-', stig_id or '')
    return m.group(1) if m else 'other'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--xccdf', required=True)
    ap.add_argument('--json')
    ap.add_argument('--md')
    ap.add_argument('--min-cluster', type=int, default=2,
                    help='conditions shared by fewer rules than this are listed individually')
    args = ap.parse_args()

    rules = parse(args.xccdf)
    if not rules:
        sys.exit('no Groups found in %s' % args.xccdf)

    withna = [r for r in rules if r['na_clause']]
    without = [r for r in rules if not r['na_clause']]
    clusters = collections.defaultdict(list)
    for r in withna:
        clusters[r['na_key']].append(r)
    big = {k: v for k, v in clusters.items() if len(v) >= args.min_cluster}
    small = [r for k, v in clusters.items() if len(v) < args.min_cluster for r in v]

    sev = collections.Counter(r['severity'] for r in rules)
    print("\n  ASD STIG triage - %s\n" % os.path.basename(args.xccdf))
    print("    rules                         %d   (high %d / medium %d / low %d)"
          % (len(rules), sev.get('high', 0), sev.get('medium', 0), sev.get('low', 0)))
    print("    carry their own N/A clause    %d   (%.0f%%)" % (len(withna), 100 * len(withna) / len(rules)))
    print("    distinct N/A conditions       %d" % len(clusters))
    print("      shared by >= %d rules        %d conditions covering %d rules"
          % (args.min_cluster, len(big), sum(len(v) for v in big.values())))
    print("      one-offs                    %d" % len(small))
    print("    NO N/A clause - need judgement %d" % len(without))

    print("\n  THE DECISIONS - answer each ONCE, it applies to every rule listed\n")
    for i, (k, v) in enumerate(sorted(big.items(), key=lambda kv: -len(kv[1])), 1):
        hi = sum(1 for r in v if r['severity'] == 'high')
        print("    %2d. [%d rules%s]" % (i, len(v), ", %d CAT I" % hi if hi else ""))
        print("        DISA: \"%s\"" % v[0]['na_clause'][:150])
        print("        %s" % ' '.join(r['vid'] for r in v[:10]) + (" ..." if len(v) > 10 else ""))
        print()

    props = collections.defaultdict(list)
    for r in withna:
        props[property_of(r['na_key'])].append(r)
    print("\n  THE SAME 139 RULES, GROUPED BY THE PROPERTY BEING ASKED ABOUT")
    print("  Each line is one question about the application. Answering it answers every rule.\n")
    for prop, v in sorted(props.items(), key=lambda kv: -len(kv[1]))[:22]:
        hi = sum(1 for r in v if r['severity'] == 'high')
        print("    %3d rules%-9s  %s" % (len(v), "  (%d CAT I)" % hi if hi else "", prop or '<unparsed>'))
    print("    %d distinct properties in total" % len(props))

    fam = collections.Counter(srg_family(r['stig_id']) for r in without)
    print("  NO N/A CLAUSE - %d rules, by SRG family:" % len(without))
    for f, n in fam.most_common():
        hi = sum(1 for r in without if srg_family(r['stig_id']) == f and r['severity'] == 'high')
        print("    %-12s %3d%s" % (f, n, "   (%d CAT I)" % hi if hi else ""))

    if args.json:
        with open(args.json, 'w') as fh:
            json.dump({'rules': rules,
                       'clusters': {k: [r['vid'] for r in v] for k, v in clusters.items()}},
                      fh, indent=2)
        print("\n  wrote %s" % args.json)

    if args.md:
        with open(args.md, 'w') as fh:
            w = fh.write
            w("# ASD STIG — triage for completion\n\n")
            w("**Generated by `scripts/asd-triage.py`. Do not edit — regenerate.**\n\n")
            w("The ASD STIG must be **completed**, not excluded: every row needs a rationale even\n")
            w("where the answer is Not Applicable. This file turns %d rules into a small number of\n" % len(rules))
            w("decisions by grouping them on **DISA's own exemption conditions**, quoted verbatim.\n\n")
            w("> **Nothing here is a rationale yet.** Applicability depends on facts about this\n")
            w("> system that are not in the XCCDF, and a rationale that paraphrases DISA's text is\n")
            w("> weaker than one that quotes it. Answer the questions below; the wording is then\n")
            w("> composed from DISA's sentence plus your system fact.\n\n")
            w("| | count |\n|---|---|\n")
            w("| Rules | **%d** (high %d / medium %d / low %d) |\n"
              % (len(rules), sev.get('high', 0), sev.get('medium', 0), sev.get('low', 0)))
            w("| Carry their own N/A clause | **%d** (%.0f%%) |\n" % (len(withna), 100 * len(withna) / len(rules)))
            w("| Distinct N/A conditions | %d |\n" % len(clusters))
            w("| Need individual judgement | **%d** |\n\n" % len(without))
            w("## The decisions — answer each once\n\n")
            for i, (k, v) in enumerate(sorted(big.items(), key=lambda kv: -len(kv[1])), 1):
                hi = sum(1 for r in v if r['severity'] == 'high')
                w("### %d. %d rules%s\n\n" % (i, len(v), " — **%d CAT I**" % hi if hi else ""))
                w("> %s\n\n" % v[0]['na_clause'])
                w("**Answer:** « N/A because … ⁄ APPLIES because … »\n\n")
                w("<details><summary>%d rules</summary>\n\n" % len(v))
                for r in v:
                    w("- `%s` %s — %s\n" % (r['vid'], r['stig_id'], r['title'][:100]))
                w("\n</details>\n\n")
            if small:
                w("### One-off conditions (%d rules)\n\n" % len(small))
                for r in small:
                    w("- `%s` %s — %s\n  > %s\n" % (r['vid'], r['stig_id'], r['title'][:90], r['na_clause'][:160]))
                w("\n")
            w("## No N/A clause — %d rules needing individual judgement\n\n" % len(without))
            w("| SRG family | rules | CAT I |\n|---|---|---|\n")
            for f, n in fam.most_common():
                hi = sum(1 for r in without if srg_family(r['stig_id']) == f and r['severity'] == 'high')
                w("| `%s` | %d | %d |\n" % (f, n, hi))
            w("\n")
            for f, _ in fam.most_common():
                w("### `%s`\n\n" % f)
                for r in without:
                    if srg_family(r['stig_id']) == f:
                        w("- `%s` %s **[%s]** — %s\n" % (r['vid'], r['stig_id'], r['severity'], r['title'][:110]))
                w("\n")
        print("  wrote %s" % args.md)
    print()


if __name__ == '__main__':
    main()
