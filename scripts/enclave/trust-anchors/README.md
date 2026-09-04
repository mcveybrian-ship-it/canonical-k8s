# Trust anchors

**Every `.crt` in this directory is installed into every machine's trust store** — by
`ca.sh trust`, by `03-host-services.sh trustca` on bare metal, and by cloud-init's
`ca_certs` module on anything the VM composer builds.

It is a directory rather than a single file because the enclave has to work at sites that
do not use this CA. A site running DoD PKI needs its roots and intermediates here instead
of — or alongside — `enclave-root.crt`. Nothing downstream cares where a certificate came
from: `enable-tls.sh` takes a fullchain and validates it against whatever is trusted.

## Adding a site's PKI

Drop the roots and any intermediates in as `.crt` files (PEM). The filename becomes the
name in `/usr/local/share/ca-certificates/`, so use something identifiable —
`dod-root-ca-3.crt`, not `ca.crt`.

**The `.crt` extension is required.** `update-ca-certificates` silently ignores anything
else, which produces a machine that looks configured and trusts nothing.

Verify what actually landed, on the machine:

```bash
### MACHINE: any ###
ls /usr/local/share/ca-certificates/
awk -v c=0 '/BEGIN CERT/{c++} END{print c" certificates in the system bundle"}' \
  /etc/ssl/certs/ca-certificates.crt
```

## Removing one

Delete the `.crt` here, then on each machine remove it from
`/usr/local/share/ca-certificates/` and run `update-ca-certificates --fresh`. Removing the
file here alone changes nothing on a machine that already installed it — the trust store is
a copy, not a mount.
