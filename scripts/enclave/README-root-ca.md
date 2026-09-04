# `root-ca.crt` — the enclave's trust anchor

**This is a public certificate and it is tracked in git deliberately.** A root CA certificate
is meant to be distributed as widely as the machines that must trust it; publishing one reveals
nothing an attacker can use, because forging a certificate requires the *private key*, which
lives only on `stage-01` at `/srv/enclave-ca/private/root.key`, encrypted, `0400 root`, and
never on any enclave machine.

Tracking it here is what lets `push-repo-to-host.sh` and `03-compose-vm.sh` install it without
a separate distribution mechanism — and a trust anchor that is awkward to distribute is one
that ends up missing from a machine, which surfaces as an opaque TLS failure.

## Verify before trusting it

```bash
openssl x509 -in root-ca.crt -noout -subject -dates -fingerprint -sha256
```

Compare the fingerprint against the one recorded in `docs/runbook.md`. If they differ, stop.

## Install it on a machine

```bash
sudo ./ca.sh trust root-ca.crt
```

Which is `/usr/local/share/ca-certificates/enclave-root.crt` plus `update-ca-certificates`.
The `.crt` extension is required — `update-ca-certificates` silently ignores anything else.

## When it changes

It does not, for ten years. If it ever must — a compromised root, or a rebuilt PKI — every
machine needs the new one installed **before** any service starts using certificates issued
under it, or everything stops at once.
