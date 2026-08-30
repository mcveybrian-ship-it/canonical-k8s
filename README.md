# Air-Gapped IL5 Kubernetes Platform Selection

A platform-selection analysis for a small, fully air-gapped DoD IL5 Kubernetes enclave —
3 physical hosts, 3 control-plane VMs, 3 worker VMs, no VMware. The deliverable is a
comparison document, published as an artifact, evaluating **Canonical Kubernetes** against
**Spectro Cloud Palette VerteX**.

> **Some documents in this repo are local-only.** `HANDOFF.md`, `docs/open-questions.md`,
> `docs/runbook.md`, `artifact/` and `archive/` are client-private engagement material and are
> gitignored — they exist on the working machine but are never pushed. Links to them below will
> not resolve in a clone. Everything else here is reusable tooling.

## Building this? Start here

**[`START-HERE.md`](START-HERE.md) — the ordered build sequence.** Steps 00 through 10, each
naming its document, its script, and what blocks it. Go there first; the files below are
reference material you will be sent to from it.

## Where things are

| File | Job |
|---|---|
| [`START-HERE.md`](START-HERE.md) | **The build order.** Steps 00–10 — the only step list |
| [`docs/00-downloads.md`](docs/00-downloads.md) | Step 00: what to download, how to verify it |
| [`docs/01-pathfinder.md`](docs/01-pathfinder.md) | Step 01: Ubuntu Pro validation on the pathfinder |
| [`docs/02-host-install.md`](docs/02-host-install.md) | Step 02: bare-metal host build |
| [`docs/open-questions.md`](docs/open-questions.md) | What is unanswered, grouped by who answers it |
| [`docs/runbook.md`](docs/runbook.md) | Reference architecture — *why* the design is what it is, with sources. Not a step list |
| [`HANDOFF.md`](HANDOFF.md) | The bake-off record — why Canonical was chosen |
| [`CLAUDE.md`](CLAUDE.md) | Working rules for Claude Code sessions |
| [`scripts/install/`](scripts/install/) | Scripts, numbered to match the steps |
| [`artifact/`](artifact/) | The published comparison document and its build script |
| [`archive/`](archive/) | The original Claude Desktop transfer bundle, verbatim |

**Naming convention:** step number = document name = script name. Step 02 is
`docs/02-host-install.md` and `scripts/install/02-*`. The runbook is the one exception —
it is reference material, cited by §-number, never a step.

`HANDOFF.md` holds what is decided; `docs/open-questions.md` holds what is not. Each fact has
one home — when an answer lands, move it, don't copy it.

## Editing the document

`artifact/artifact-source.html` is written **without** `<!doctype>`, `<html>`, `<head>` or
`<body>` tags, because the Artifact tool supplies that wrapper at publish time. The
standalone file adds the same wrapper so the document opens as an ordinary file.

```bash
# after editing artifact/artifact-source.html
python scripts/build_standalone.py           # regenerate the standalone
python scripts/build_standalone.py --check   # verify it is current (exit 1 if stale)
```

Never hand-edit `artifact/bakeoff-standalone.html` — the next build overwrites it.

## Publishing

The document is live at
<https://claude.ai/code/artifact/877d7682-3493-41b6-953c-51af4c96706a>.

To update **that same link**, call the Artifact tool with `artifact/artifact-source.html`
**and** that URL as the `url` parameter. Omitting the `url` creates a second artifact
instead of updating this one. Keep these stable across redeploys — readers find the page
by them:

- **Title:** `Air-Gapped IL5 Platform Bake-Off`
- **Favicon:** 🛰️
- **Description:** must match `DESCRIPTION` in `scripts/build_standalone.py`

Then regenerate the standalone so the two copies do not drift.

## Ground rules

Three that matter more than the rest — the full set is in [`CLAUDE.md`](CLAUDE.md):

1. **Never invent pricing, certification status, or version numbers.** Anything factual
   about a product comes from a source fetched in-session, and the source goes in the
   document's Sources list. If a number is not public, model it as a variable and say so.
2. **Precision on compliance language.** "FedRAMP Moderate in process" is not "FedRAMP
   authorized." "FIPS 140-3 validated" is not "FIPS mode." Nothing is "IL5 certified."
3. **Show the trade-off.** The value here is in what the vendor decks omit.
