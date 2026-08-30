# Project: Air-Gapped IL5 Kubernetes Platform Selection

Read `HANDOFF.md` before doing anything — it carries the locked decisions and verified
findings from the prior session. Then read `docs/open-questions.md` for what is still
unanswered. `README.md` has the repository map and the build/publish workflow.

## What this project is

A platform-selection analysis for a small, fully air-gapped DoD IL5 Kubernetes enclave —
3 physical hosts, 3 control-plane VMs, 3 worker VMs, no VMware. The deliverable is a
comparison document, published as an artifact, evaluating **Canonical Kubernetes** against
**Spectro Cloud Palette VerteX**.

## Working rules

**Never invent pricing, certification status, or version numbers.** Vendor posture in this
space changes quarterly and the reader is making a procurement decision. Anything factual
about a product must come from a source you fetched in this session, and the source goes
in the document's Sources list. If a number is not public — Spectro Cloud's list price is
not — say so and model it as a variable rather than guessing.

**Precision on compliance language.** "FedRAMP Moderate in process" is not "FedRAMP
authorized". "FIPS 140-3 validated" is not "FIPS mode". Nothing is "IL5 certified". These
distinctions are the point of the document; a sloppy paraphrase makes it useless.

**Re-verify before restating.** The time-sensitive claims are tracked under "Re-verify
before anything ships" in `docs/open-questions.md`. Re-fetch those sources before any
final version ships — do not restate them from memory or from this repo.

**Show the trade-off, don't hide it.** The prior session's value came from surfacing
things the vendor decks omit — that VerteX stacks on Ubuntu Pro rather than replacing it,
that dropping VMware collapses the FIPS CSI list to Longhorn, that replica-3 across three
nodes cannot self-heal. Keep that posture.

**One home per fact.** `HANDOFF.md` is what is settled; `docs/open-questions.md` is what is
not. When a question gets answered, move the finding into `HANDOFF.md` §3 with its source
and close the row — do not leave a copy behind in both files.

## How to work here

Corrections earned the hard way across the 2026-08-27/30 sessions. All of them were given
after getting it wrong first. Read them as constraints, not suggestions.

**Do not add files — fix the ones that exist.** A second document for step 01 produced two
`01-*.md` and two `02-*.md`. His words: *"are we just adding files"*. One document per step,
updated in place. A new file only when there is genuinely a new step or a new mechanism.

**Never give a single-platform answer.** He works from Windows/PowerShell and builds Ubuntu.
Either cover both, or state plainly why only one applies — `01-*.sh` runs on the Ubuntu
target, so bash-only is correct there and saying so is the answer. Audit the scripts rather
than trusting memory about which exist.

**Nothing hardcoded when it could be a parameter.** *"I hate things hard coded when there
are options."* Disk serials, addresses, LV sizes, usernames, NIC names all belong in
`host-params.env`.

**Stop narrating.** Full analyses after every step drown the work: *"You went down a god
damn rabbit hole."* Give the next command and a one-line reason. Save the analysis for when
something is actually broken.

**Verify on his machine, do not assert.** Several "this works" claims were wrong until
actually run against his hardware. He calls it out fast: *"half ass paragraph does not tell
me shit."* Run it, paste the real output, and say plainly which parts you could not verify.

**Why this matters:** he is a consultant producing an auditable build procedure. A wrong doc
or a command that only works on one OS costs a trip to the rack, and the deliverable is
supposed to be repeatable by someone else.

## Two machines, and what git will not carry

**STAGE-01 (`10.0.20.160`) owns this repo as of 2026-08-30.** The Windows working copy is a
backup and the seed-stick writer. Work on STAGE-01 over VS Code Remote-SSH.

**Five paths are gitignored and git cannot sync them** — `HANDOFF.md`,
`docs/open-questions.md`, `docs/runbook.md`, `artifact/`, `archive/`. Two copies diverge
silently. Move them with `scripts/private-sync.sh pack|unpack`, never git, and re-pack
whenever one changes on the authoritative machine.

**`origin` is public.** Enable the guard in every clone — git does not track `.git/hooks`:

```bash
git config core.hooksPath .githooks
```

That refuses any push carrying the private paths, including the local `prehistory` branch
under any name. See the top of `docs/open-questions.md`.

## Scripts

Build scripts live in `scripts/install/`, numbered to match the steps in `START-HERE.md`.

**Encoding rules, enforced by `.gitattributes`:**

- **`.ps1` files must be ASCII-only and saved UTF-8 *with BOM*, CRLF.** Windows PowerShell
  5.1 reads `.ps1` as the system ANSI codepage unless a BOM is present, so a UTF-8 em-dash
  becomes three garbage bytes and the file fails to parse. Use `-` not `-`, plain quotes,
  no smart punctuation. Verify with
  `[System.Management.Automation.Language.Parser]::ParseFile(...)` before committing.
- **`.sh`, `user-data` and `meta-data` must be LF.** CRLF breaks the shebang and breaks
  cloud-init parsing. This holds **on removable media too** - re-verify after copying to a
  thumb drive, because files pick up CRLF in transit. See `docs/airgap-media.md`.
- Target PowerShell **5.1**, not 7: no ternary, no `??`, no `-AsHashtable`, and force TLS 1.2
  before any download.

Validate before committing: `bash -n` for shell, the PowerShell parser for `.ps1`, and
`yaml.safe_load` for autoinstall configs.

## Editing the document

`artifact/artifact-source.html` is the source of truth. It is written **without**
`<!doctype>`, `<html>`, `<head>` or `<body>` tags because the Artifact tool wraps it at
publish time. `artifact/bakeoff-standalone.html` is generated — never edit it by hand.
After any change to the source:

```bash
python scripts/build_standalone.py
```

The page has an established design system defined in `:root` at the top of the source —
Saira Condensed for display, IBM Plex Sans for body, IBM Plex Mono for data, a steel-blue
accent on cool neutrals, squared corners and hairline rules. Light and dark are both
defined at token level, with an un-stamped `prefers-color-scheme` block and a
`[data-theme="dark"]` block. **Extend the tokens; do not introduce new literal colors** —
a color declared only inside a media or `[data-theme]` block will render one theme's text
on the other theme's ground.

To republish to the existing URL, pass the file path **and**
`url: https://claude.ai/code/artifact/877d7682-3493-41b6-953c-51af4c96706a`. Keep the
title "Air-Gapped IL5 Platform Bake-Off" and the 🛰️ favicon stable — the reader finds the
page by them. Keep the artifact `description` identical to `DESCRIPTION` in
`scripts/build_standalone.py`.

## Tone of the document

Written for a consultant briefing a program office. Direct, specific, unhedged where the
evidence supports it and explicitly uncertain where it doesn't. It states verdicts ("on a
single small enclave, Canonical wins on cost and it isn't close") rather than laying out
options and retreating. Keep that voice.
