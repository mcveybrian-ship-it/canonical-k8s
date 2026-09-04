#!/usr/bin/env bash
# =========================================================================================
# ca.sh - the enclave's internal PKI.
#
#     ON stage-01 (outside the enclave - the root lives here):
#       ./ca.sh init-root                 create the root CA
#       ./ca.sh sign-issuing <csr>        sign the issuing CA's CSR
#
#     ON svc-mgmt-01 (the management plane - issuance lives here):
#       sudo ./ca.sh init-issuing         create the issuing key and its CSR
#       sudo ./ca.sh install-issuing <crt>  install the signed certificate
#       sudo ./ca.sh issue <name> [san...]  issue a cert for a service ON THIS machine
#       sudo ./ca.sh sign-server <csr>      sign a CSR from another machine
#
#     ON any machine needing a certificate:
#       sudo ./ca.sh request [name] [san...]  generate a key HERE and a CSR to send
#
#     ON any machine:
#       sudo ./ca.sh trust <root.crt>     install the root into the trust store
#       ./ca.sh show <file>               summarise a cert, without dumping it
#       ./ca.sh inventory                 every cert here, and how long it has left
#
#     ON stage-01, onto removable media:
#       sudo ./ca.sh backup-root <dir>    the root CA - THE single point of failure
#
# WHY AN INTERNAL CA AT ALL
#   Everything the enclave serves is currently HTTP: the apt mirror, the contracts server,
#   and shortly Harbor and MAAS. "Self-signed" is a finding in most DoD assessments while
#   "internal PKI with documented key management" is defensible - and they are not the same
#   thing to an assessor even though the crypto is similar. Air-gapped does not exempt
#   data-in-transit requirements.
#
# WHY THE ROOT KEY NEVER TOUCHES AN ENCLAVE MACHINE
#   The issuing CA's private key is generated ON svc-mgmt-01 and never leaves it. Only a CSR
#   travels to the root. If the enclave is ever compromised, the root is not - and the root is
#   what every machine trusts.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS="${CA_PARAMS:-$SELF/ca-params.env}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
skip() { printf '  [--] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

# `trust` and `show` need NO parameters - they install or read a certificate and nothing more.
# Requiring a params file for them meant every machine that only has to TRUST the CA needed a
# copy of the CA's configuration, which is both pointless and misleading about what that
# machine does. Found on svc-repo-01, which will never issue anything.
# `trust` and `show` need nothing. `request` needs only the identity fields and key size,
# all of which have defaults - so a machine that merely needs a certificate does not have to
# carry the CA's configuration. Only the operations that actually run a CA do.
# =========================================================================================
# inventory - what certificates does this machine hold, and when do they die?
#
# Leaf certificates are 365 days. In a connected estate something renews them automatically;
# in an air gap there is no ACME, no reminder, and nothing that fails loudly until a service
# stops answering. The first warning would otherwise be apt refusing to talk to the mirror.
# Run this on each machine, or read the calendar in runbook 2.9b.
# =========================================================================================
cmd_inventory() {
  local now days f cn end left warn_at="${CA_WARN_DAYS:-90}" found=0 expiring=0
  now=$(date +%s)
  printf '  %-46s %-22s %s\n' "CERTIFICATE (file)" "EXPIRES" "DAYS LEFT"
  printf '  %-46s %-22s %s\n' "----------------------------------------------" "----------------------" "---------"
  # Every place a cert legitimately lives. Private keys are never read.
  for f in /etc/ssl/enclave/*.crt /etc/enclave-ca/certs/*.crt \
           /srv/enclave-ca/certs/*.crt /usr/local/share/ca-certificates/*.crt; do
    [ -r "$f" ] || continue
    case "$f" in *fullchain*) continue ;; esac   # the leaf is already listed on its own
    end=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2) || continue
    [ -n "$end" ] || continue
    cn=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/.*CN *= *//; s/,.*//')
    # The same CA legitimately appears under several filenames - issuing.crt and chain.crt
    # both carry the issuing cert. Naming the file makes that read as two copies rather
    # than as a duplicate row nobody can explain.
    cn="$cn  ($(basename "$f"))"
    days=$(date -d "$end" +%s 2>/dev/null) || continue
    left=$(( (days - now) / 86400 ))
    found=$((found + 1))
    if [ "$left" -lt 0 ]; then
      printf '  %-46s %-22s %s\n' "$cn" "$end" "EXPIRED"
      expiring=$((expiring + 1))
    elif [ "$left" -lt "$warn_at" ]; then
      printf '  %-46s %-22s %s\n' "$cn" "$end" "$left  <-- RENEW"
      expiring=$((expiring + 1))
    else
      printf '  %-46s %-22s %s\n' "$cn" "$end" "$left"
    fi
  done
  say ""
  [ "$found" -gt 0 ] || { say "no enclave certificates on this machine"; return 0; }
  if [ "$expiring" -gt 0 ]; then
    say "$expiring certificate(s) need attention within $warn_at days."
    say "Renew a leaf by repeating how it was issued - there is no separate renew path:"
    say "    sudo ./ca.sh request <name>          # on the machine that needs it"
    say "    sudo ./ca.sh sign-server <csr>       # on svc-mgmt-01"
    say "    sudo ./enable-tls.sh <name> <fullchain.crt> --root|--proxy ..."
  else
    ok "nothing expiring within $warn_at days"
  fi
}

# =========================================================================================
# backup-root - the root CA onto removable media. stage-01 only.
#
# THIS IS THE SINGLE POINT OF FAILURE IN THE WHOLE PKI. The root key exists in exactly one
# place, /srv/enclave-ca/private/root.key on stage-01, and private-sync.sh does not carry it.
# If that disk dies, every machine in the enclave trusts an anchor that can never issue
# again: recovery is a new root, a new issuing CA, and a physical visit to every machine to
# replace the trust store. That is a rebuild, not an incident.
#
# The key is already passphrase-encrypted, so this deliberately does NOT add a second
# passphrase - one more secret to lose protects nothing the first one does not. What matters
# is that the tarball goes to media kept OFFLINE and PHYSICALLY SEPARATE from stage-01, and
# that the passphrase is stored somewhere other than beside it.
# =========================================================================================
cmd_backup_root() {
  local dest="${1:-}"
  [ -n "$dest" ] || die "usage: sudo ./ca.sh backup-root <destination-directory>"
  [ -d "$dest" ] || die "not a directory: $dest"
  [ -d "$CA_ROOT_DIR/private" ] || die "no root CA at $CA_ROOT_DIR - this is not the root host"
  _is_issuing_host && die "this machine holds the ISSUING CA. The root does not live here."

  local out
  out="$dest/enclave-ca-root-$(date +%Y-%m-%d).tar.gz"
  [ -e "$out" ] && die "already exists, refusing to overwrite: $out"

  # -C so the archive holds relative paths: it can be restored anywhere, not only to /srv.
  tar -czf "$out" -C "$(dirname "$CA_ROOT_DIR")" "$(basename "$CA_ROOT_DIR")" \
    || die "tar failed - nothing usable was written"
  chmod 0400 "$out"

  # Prove it reads back HERE, while the original is still present. A backup verified only at
  # restore time is a backup verified when it is already too late.
  tar -tzf "$out" >/dev/null 2>&1 || die "the archive does not read back - do not trust it"
  local n; n=$(tar -tzf "$out" | grep -c . )
  sha256sum "$out" | awk '{print $1}' > "$out.sha256"
  ok "wrote $out"
  ok "$n entries, archive verified readable"
  ok "sha256 recorded in $out.sha256"
  say ""
  say "  This archive contains the root PRIVATE KEY. It is passphrase-encrypted; the"
  say "  passphrase is NOT in the archive and must be stored separately."
  say ""
  say "  Keep it OFFLINE and physically apart from stage-01. Two copies, two locations."
  say "  Verify a copy on arrival:  sha256sum -c $(basename "$out").sha256"
}

case "${1:-}" in
  trust|show|request|inventory) CA_NEED_PARAMS=0 ;;
  *)                  CA_NEED_PARAMS=1 ;;
esac

if [ "$CA_NEED_PARAMS" -eq 1 ]; then
  [ -r "$PARAMS" ] || die "no params at $PARAMS
       cp $SELF/ca-params.env.example $PARAMS && chmod 600 $PARAMS"
  # shellcheck disable=SC1090
  . "$PARAMS"
  : "${CA_COUNTRY:?}" "${CA_ORG:?}" "${CA_OU:?}" "${CA_ROOT_CN:?}" "${CA_ISSUING_CN:?}"
  : "${CA_KEY_BITS:?}" "${CA_DIGEST:?}" "${CA_ROOT_DAYS:?}" "${CA_ROOT_DIR:?}" "${CA_ISSUING_DIR:?}"
elif [ -r "$PARAMS" ]; then
  # shellcheck disable=SC1090
  . "$PARAMS"
elif [ -r "$SELF/ca-params.env.example" ]; then
  # Every line in the example is VAR="${VAR:-default}", so sourcing it only supplies defaults
  # and overrides nothing. That gives a machine issuing a CSR the same C/O/OU as every other
  # certificate in the enclave, WITHOUT it needing a copy of the live CA configuration - a
  # subject that differs from the rest is a certificate that looks like it came from somewhere
  # else.
  # shellcheck disable=SC1091
  . "$SELF/ca-params.env.example"
fi

# The domain and addresses come from the same file everything else uses, so a certificate
# cannot name a host the addressing plan does not. Only needed by 'issue', which lands next.
ADDRS="${CA_ADDRS:-$SELF/enclave-addresses.env}"
if [ -r "$ADDRS" ]; then
  # shellcheck disable=SC1090
  . "$ADDRS"
  CA_HAVE_ADDRS=1
else
  CA_HAVE_ADDRS=0
fi
DOMAIN="${ENCLAVE_DOMAIN:-enclave.internal}"
export DOMAIN

subj() { printf '/C=%s/O=%s/OU=%s/CN=%s' "$CA_COUNTRY" "$CA_ORG" "$CA_OU" "$1"; }

# --- keep the two halves of the PKI on their own machines --------------------------------
# The root and the issuing CA must never live on the same host: the whole point is that a
# compromise of the enclave does not reach the key every machine trusts. Nothing but these
# checks was stopping `init-issuing` being run on stage-01 by mistake - which happened.
_is_root_host()    { [ -e "$CA_ROOT_DIR/private/root.key" ]; }
_is_issuing_host() { [ -e "$CA_ISSUING_DIR/private/issuing.key" ]; }

require_root_host() {
  _is_issuing_host && die "this machine holds the ISSUING CA ($CA_ISSUING_DIR).
       Root operations belong on stage-01, outside the enclave."
  :
}
require_issuing_host() {
  _is_root_host && die "this machine holds the ROOT CA ($CA_ROOT_DIR).
       The issuing CA must live on a DIFFERENT machine - svc-mgmt-01 - so that a compromise
       of the enclave cannot reach the root key. Run this there.
       If a partial issuing CA was created here by mistake, remove it:
         sudo rm -rf $CA_ISSUING_DIR"
  :
}

# =========================================================================================
cmd_init_root() {
  require_root_host
  local d="$CA_ROOT_DIR"
  [ -e "$d/private/root.key" ] && die "a root CA already exists at $d.
       Refusing to overwrite it - every certificate ever issued chains to that key.
       Move it aside deliberately if you really mean to start over."

  # 0755 on the directory and on certs/, 0700 on private/. Certificates are PUBLIC - the root
  # cert has to reach every machine's trust store - and locking them inside a 0700 directory
  # means even reading one needs root, which is friction with no security value. The key is
  # what needs protecting, and it is the only thing that gets it.
  install -d -m 0755 "$d" "$d/certs"
  install -d -m 0700 "$d/private" "$d/newcerts"
  : > "$d/index.txt"; echo 1000 > "$d/serial"; chmod 0644 "$d/index.txt" "$d/serial"

  cat > "$d/openssl.cnf" <<CNF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir               = $d
certs             = \$dir/certs
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
private_key       = \$dir/private/root.key
certificate       = \$dir/certs/root.crt
default_md        = $CA_DIGEST
policy            = policy_loose
email_in_dn       = no
rand_serial       = no
unique_subject    = no
[ policy_loose ]
countryName             = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
[ req ]
default_bits       = $CA_KEY_BITS
distinguished_name = req_dn
string_mask        = utf8only
default_md         = $CA_DIGEST
x509_extensions    = v3_root
[ req_dn ]
[ v3_root ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
[ v3_issuing ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
# pathlen:0 - the issuing CA may sign end-entity certificates and NOTHING ELSE. It cannot
# create a further CA, so a compromise of svc-mgmt-01 cannot mint new authorities.
basicConstraints       = critical, CA:true, pathlen:0
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
CNF
  chmod 0600 "$d/openssl.cnf"

  # The key is encrypted. An unencrypted root key on disk is the single worst artefact in a
  # PKI, and it is the first thing an assessor looks for.
  # PROMPTING is the right default for a root key - a passphrase in a file is a passphrase
  # that leaks with the file. CA_ROOT_PASS_FILE exists so the flow can be tested and so a
  # rebuild can be automated deliberately; it is not how the real root should be created.
  if [ -n "${CA_ROOT_PASS_FILE:-}" ]; then
    [ -r "$CA_ROOT_PASS_FILE" ] || die "CA_ROOT_PASS_FILE=$CA_ROOT_PASS_FILE is not readable"
    [ "$(stat -c '%a' "$CA_ROOT_PASS_FILE")" = "600" ] \
      || die "$CA_ROOT_PASS_FILE must be mode 600 - it protects the root key"
    warn "using a passphrase FILE. Acceptable for a test root; for the real one, let it prompt."
    openssl genrsa -aes256 -passout "file:$CA_ROOT_PASS_FILE" \
      -out "$d/private/root.key" "$CA_KEY_BITS" 2>/dev/null || die "root key generation failed"
    PASSIN=(-passin "file:$CA_ROOT_PASS_FILE")
  else
    say "You will be asked for a passphrase for the ROOT key. Choose a strong one and record"
    say "it somewhere durable - WITHOUT IT YOU CANNOT SIGN A NEW ISSUING CA, EVER."
    say ""
    openssl genrsa -aes256 -out "$d/private/root.key" "$CA_KEY_BITS" 2>/dev/null \
      || die "root key generation failed"
    PASSIN=()
  fi
  chmod 0400 "$d/private/root.key"
  ok "root key: $d/private/root.key ($CA_KEY_BITS-bit RSA, encrypted, 0400)"

  openssl req -config "$d/openssl.cnf" -key "$d/private/root.key" "${PASSIN[@]}" \
    -new -x509 -days "$CA_ROOT_DAYS" -"$CA_DIGEST" -extensions v3_root \
    -subj "$(subj "$CA_ROOT_CN")" -out "$d/certs/root.crt" \
    || die "root certificate creation failed"
  chmod 0444 "$d/certs/root.crt"
  ok "root cert: $d/certs/root.crt (valid $CA_ROOT_DAYS days)"
  say ""
  cmd_show "$d/certs/root.crt"
  say ""
  say "  This certificate is PUBLIC - it goes into every machine's trust store."
  say "  The key beside it is not. Back it up, and for production move it to removable"
  say "  encrypted media or a token: the AO will ask where it lives."
}

# =========================================================================================
cmd_sign_issuing() {
  require_root_host
  local csr="${1:-}"; [ -r "$csr" ] || die "usage: $0 sign-issuing <issuing.csr>"
  local d="$CA_ROOT_DIR"
  [ -r "$d/private/root.key" ] || die "no root CA at $d - run init-root first"

  openssl req -in "$csr" -noout -subject 2>/dev/null | sed 's/^/  csr subject: /' \
    || die "$csr is not a valid CSR"

  local PASSIN=()
  [ -n "${CA_ROOT_PASS_FILE:-}" ] && PASSIN=(-passin "file:$CA_ROOT_PASS_FILE")
  openssl ca -config "$d/openssl.cnf" -extensions v3_issuing "${PASSIN[@]}" \
    -days "${CA_ISSUING_DAYS:-1826}" -notext -md "$CA_DIGEST" \
    -in "$csr" -out "$d/certs/issuing.crt" -batch \
    || die "signing failed"
  chmod 0444 "$d/certs/issuing.crt"
  ok "signed: $d/certs/issuing.crt"

  cat "$d/certs/issuing.crt" "$d/certs/root.crt" > "$d/certs/chain.crt"
  chmod 0444 "$d/certs/chain.crt"
  ok "chain:  $d/certs/chain.crt (issuing + root)"
  say ""
  cmd_show "$d/certs/issuing.crt"
  say ""
  say "  Copy BOTH to svc-mgmt-01:"
  say "    $d/certs/issuing.crt"
  say "    $d/certs/root.crt"
}

# =========================================================================================
cmd_init_issuing() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  require_issuing_host
  local d="$CA_ISSUING_DIR"
  [ -e "$d/private/issuing.key" ] && die "an issuing CA already exists at $d.
       Refusing to overwrite - every certificate it has issued chains to that key."

  install -d -m 0755 "$d" "$d/certs"
  install -d -m 0700 "$d/private" "$d/newcerts"
  : > "$d/index.txt"; echo 1000 > "$d/serial"; chmod 0644 "$d/index.txt" "$d/serial"

  cat > "$d/openssl.cnf" <<CNF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir               = $d
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
private_key       = \$dir/private/issuing.key
certificate       = \$dir/certs/issuing.crt
default_md        = $CA_DIGEST
policy            = policy_loose
email_in_dn       = no
rand_serial       = no
unique_subject    = no
copy_extensions   = copy
[ policy_loose ]
countryName             = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
[ req ]
default_bits       = ${CA_LEAF_KEY_BITS:-3072}
distinguished_name = req_dn
string_mask        = utf8only
default_md         = $CA_DIGEST
[ req_dn ]
[ v3_server ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer
CNF
  chmod 0644 "$d/openssl.cnf"

  # The issuing key is generated HERE and never leaves. Only the CSR travels to the root.
  openssl genrsa -out "$d/private/issuing.key" "$CA_KEY_BITS" 2>/dev/null \
    || die "issuing key generation failed"
  chmod 0400 "$d/private/issuing.key"
  ok "issuing key: $d/private/issuing.key ($CA_KEY_BITS-bit RSA, 0400) - never leaves this host"

  openssl req -new -key "$d/private/issuing.key" -"$CA_DIGEST" \
    -subj "$(subj "$CA_ISSUING_CN")" -out "$d/issuing.csr" || die "CSR creation failed"
  chmod 0444 "$d/issuing.csr"
  ok "CSR: $d/issuing.csr"
  say ""
  say "  Carry the CSR to stage-01 and sign it:"
  say "    ./ca.sh sign-issuing issuing.csr"
  say "  then bring back issuing.crt and root.crt and run:"
  say "    sudo ./ca.sh install-issuing issuing.crt root.crt"
}

# =========================================================================================
cmd_install_issuing() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  require_issuing_host
  local crt="${1:-}" root="${2:-}"
  [ -r "$crt" ] && [ -r "$root" ] || die "usage: sudo $0 install-issuing <issuing.crt> <root.crt>"
  local d="$CA_ISSUING_DIR"
  [ -r "$d/private/issuing.key" ] || die "no issuing key at $d - run init-issuing first"

  # A certificate that does not match the key is the classic PKI failure, and it surfaces as
  # an opaque TLS error weeks later. Compare the public keys before installing anything.
  local a b
  a=$(openssl x509 -in "$crt" -noout -pubkey | openssl sha256 | awk '{print $2}')
  b=$(openssl rsa -in "$d/private/issuing.key" -pubout 2>/dev/null | openssl sha256 | awk '{print $2}')
  [ "$a" = "$b" ] || die "$crt does NOT match the issuing key in $d.
       Signed the wrong CSR, or copied the wrong certificate back."
  ok "certificate matches the issuing key"

  # And that it actually chains to the root - a self-signed cert would install happily.
  openssl verify -CAfile "$root" "$crt" >/dev/null 2>&1 \
    || die "$crt does not verify against $root"
  ok "chains to the root"

  install -m 0444 "$crt"  "$d/certs/issuing.crt"
  install -m 0444 "$root" "$d/certs/root.crt"
  cat "$d/certs/issuing.crt" "$d/certs/root.crt" > "$d/certs/chain.crt"
  chmod 0444 "$d/certs/chain.crt"
  ok "installed: issuing.crt, root.crt, chain.crt in $d/certs/"
  say ""
  cmd_show "$d/certs/issuing.crt"
}

# =========================================================================================
cmd_issue() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  require_issuing_host
  local name="${1:-}"; shift || true
  [ -n "$name" ] || die "usage: sudo $0 issue <hostname> [extra-SAN ...]"
  local d="$CA_ISSUING_DIR"
  [ -r "$d/private/issuing.key" ] || die "no issuing CA at $d"
  [ -r "$d/certs/issuing.crt" ]   || die "issuing CA is not signed yet - see install-issuing"

  # SANs from the addressing plan, so a certificate cannot name a host the plan does not.
  # Modern clients ignore CN entirely and match on SAN, so a missing IP SAN means anything
  # reaching the service BY ADDRESS fails - which is exactly what happens during a DNS outage,
  # when you least want a second problem.
  local var ip sans
  var=$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')
  ip="${!var:-}"
  sans="DNS:$name.$DOMAIN,DNS:$name"
  if [ -n "$ip" ]; then
    sans="$sans,IP:$ip"
  else
    # Refuse rather than issue quietly. A certificate without an IP SAN works perfectly until
    # something connects by address - which is precisely what happens during a DNS problem,
    # when a second failure is least welcome. Modern clients ignore CN entirely and match on
    # SAN only, so the omission is total, not partial.
    [ "$CA_HAVE_ADDRS" -eq 1 ] \
      || die "no address file at $ADDRS, so no IP SAN can be added.
       Point CA_ADDRS at enclave-addresses.env, or pass the address explicitly:
         sudo $0 issue $name <ip>"
    warn "$name has no entry ($var) in $ADDRS - issuing with DNS SANs only"
    warn "if anything reaches this service by IP, the certificate will be rejected"
  fi
  for extra in "$@"; do
    case "$extra" in
      *[0-9].[0-9]*) sans="$sans,IP:$extra" ;;
      *)             sans="$sans,DNS:$extra" ;;
    esac
  done
  say "name : $name.$DOMAIN"
  say "sans : $sans"

  local out="$d/certs/$name"
  install -d -m 0755 "$d/certs"
  openssl genrsa -out "$out.key" "${CA_LEAF_KEY_BITS:-3072}" 2>/dev/null || die "key generation failed"
  chmod 0640 "$out.key"
  openssl req -new -key "$out.key" -"$CA_DIGEST" \
    -subj "$(subj "$name.$DOMAIN")" \
    -addext "subjectAltName=$sans" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    -out "$out.csr" || die "CSR creation failed"

  openssl ca -config "$d/openssl.cnf" -extensions v3_server \
    -days "${CA_LEAF_DAYS:-365}" -notext -md "$CA_DIGEST" \
    -in "$out.csr" -out "$out.crt" -batch || die "signing failed"
  chmod 0444 "$out.crt"
  # Servers need leaf + issuing so a client holding only the root can build the chain.
  cat "$out.crt" "$d/certs/issuing.crt" > "$out.fullchain.crt"
  chmod 0444 "$out.fullchain.crt"
  rm -f "$out.csr"

  ok "issued $out.crt"
  ok "fullchain $out.fullchain.crt (leaf + issuing - serve THIS, not the bare cert)"
  say ""
  cmd_show "$out.crt"
}

# =========================================================================================
cmd_request() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  local name="${1:-$(hostname -s)}"; shift || true
  local d=/etc/ssl/enclave
  install -d -m 0755 "$d"

  # THE KEY IS GENERATED HERE AND NEVER MOVES. `issue` on svc-mgmt-01 is for services running
  # ON svc-mgmt-01; for anything else, a key generated centrally has to travel - through /tmp
  # on at least two machines, readable by root on each, recoverable from the filesystem after
  # deletion. Exactly the reasoning that keeps the issuing key off stage-01, applied one level
  # down. Only a CSR leaves this host.
  [ -e "$d/$name.key" ] && die "a key already exists at $d/$name.key.
       Reusing it is fine - send $d/$name.csr for signing. Delete both only if you mean to
       invalidate every certificate issued against that key."

  local ip sans var
  var=$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')
  ip="${!var:-}"
  # Fall back to this machine's own address rather than omitting the SAN - the addressing file
  # may not be present on a host that only needs a certificate.
  [ -z "$ip" ] && ip=$(ip -4 -br addr | awk '$1!="lo"{split($3,a,"/"); print a[1]; exit}')
  sans="DNS:$name.$DOMAIN,DNS:$name"
  [ -n "$ip" ] && sans="$sans,IP:$ip"
  for extra in "$@"; do
    case "$extra" in
      *[0-9].[0-9]*) sans="$sans,IP:$extra" ;;
      *)             sans="$sans,DNS:$extra" ;;
    esac
  done

  openssl genrsa -out "$d/$name.key" "${CA_LEAF_KEY_BITS:-3072}" 2>/dev/null || die "key generation failed"
  chmod 0640 "$d/$name.key"; chgrp root "$d/$name.key"
  ok "key: $d/$name.key (never leaves this host)"

  openssl req -new -key "$d/$name.key" -"${CA_DIGEST:-sha256}" \
    -subj "/C=${CA_COUNTRY:-US}/O=${CA_ORG:-Enclave}/OU=${CA_OU:-Enclave PKI}/CN=$name.$DOMAIN" \
    -addext "subjectAltName=$sans" -out "$d/$name.csr" || die "CSR creation failed"
  chmod 0444 "$d/$name.csr"
  ok "csr: $d/$name.csr"
  say "sans: $sans"
  say ""
  # Print the FULL path. A bare filename reads as "it is in the current directory", which it
  # is not - it is in /etc/ssl/enclave - and the next command then fails with a usage error
  # that says nothing about the real problem.
  say "  Send the CSR to svc-mgmt-01 and sign it:"
  say "    sudo ./ca.sh sign-server $d/$name.csr"
  say "  then bring back $name.fullchain.crt and drop it in $d/"
}

# =========================================================================================
cmd_sign_server() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  require_issuing_host
  local csr="${1:-}"; [ -r "$csr" ] || die "usage: sudo $0 sign-server <name.csr>"
  local d="$CA_ISSUING_DIR"
  [ -r "$d/certs/issuing.crt" ] || die "issuing CA is not signed yet"

  openssl req -in "$csr" -noout -verify >/dev/null 2>&1 || die "$csr is not a valid CSR"
  local cn; cn=$(openssl req -in "$csr" -noout -subject | sed 's/.*CN *= *//;s/,.*//')
  local name="${cn%%.*}"
  say "signing: $cn"
  # `-ext` is an x509 option, NOT a req option - `openssl req -noout -ext ...` errors, and
  # under `set -o pipefail` that took the whole script down after printing one line and
  # nothing else. Third time a diagnostic pipeline has killed a script in this project.
  # Diagnostics must never be able to fail the thing they are describing: `|| true`.
  openssl req -in "$csr" -noout -text 2>/dev/null \
    | grep -A1 -i 'Subject Alternative Name' | sed 's/^/  /' || true

  # copy_extensions=copy in the issuing config carries the CSR's SANs into the certificate.
  # Without it a certificate signs cleanly and arrives with NO SANs at all, which modern
  # clients reject outright - and the error names the hostname, not the missing extension.
  openssl ca -config "$d/openssl.cnf" -extensions v3_server \
    -days "${CA_LEAF_DAYS:-365}" -notext -md "${CA_DIGEST:-sha256}" \
    -in "$csr" -out "$d/certs/$name.crt" -batch || die "signing failed"
  chmod 0444 "$d/certs/$name.crt"
  cat "$d/certs/$name.crt" "$d/certs/issuing.crt" > "$d/certs/$name.fullchain.crt"
  chmod 0444 "$d/certs/$name.fullchain.crt"

  local n; n=$(openssl x509 -in "$d/certs/$name.crt" -noout -ext subjectAltName 2>/dev/null | grep -c ':' || true)
  [ "$n" -ge 1 ] || die "the signed certificate has NO subjectAltName - check copy_extensions"
  ok "signed: $d/certs/$name.fullchain.crt (send THIS back, not the bare cert)"
  say ""
  cmd_show "$d/certs/$name.crt"
}

# =========================================================================================
cmd_show() {
  local f="${1:-}"; [ -r "$f" ] || die "usage: $0 show <certificate>"
  # Every pipeline here is guarded. cmd_show is called at the END of init-root, sign-issuing,
  # issue and sign-server - so a failure inside it would report failure on work that has
  # already succeeded, and send someone looking for a problem in the wrong place.
  openssl x509 -in "$f" -noout -subject -issuer -dates \
    -ext basicConstraints,keyUsage,subjectAltName 2>/dev/null | sed 's/^/    /' || true
  printf '    fingerprint: %s\n' \
    "$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || echo unavailable)"
}

# =========================================================================================
cmd_trust() {
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  local f="${1:-}"; [ -r "$f" ] || die "usage: sudo $0 trust <root.crt>"
  openssl x509 -in "$f" -noout >/dev/null 2>&1 || die "$f is not a certificate"
  # .crt in /usr/local/share/ca-certificates is the Debian/Ubuntu convention; anything else
  # is silently ignored by update-ca-certificates.
  install -m 0644 "$f" /usr/local/share/ca-certificates/enclave-root.crt
  update-ca-certificates 2>&1 | sed 's/^/  /'
  ok "root CA trusted on $(hostname)"
}

case "${1:-}" in
  init-root)      cmd_init_root ;;
  sign-issuing)   shift; cmd_sign_issuing "$@" ;;
  init-issuing)   cmd_init_issuing ;;
  install-issuing) shift; cmd_install_issuing "$@" ;;
  issue)          shift; cmd_issue "$@" ;;
  request)        shift; cmd_request "$@" ;;
  sign-server)    shift; cmd_sign_server "$@" ;;
  trust)          shift; cmd_trust "$@" ;;
  show)           shift; cmd_show "$@" ;;
  inventory)      cmd_inventory ;;
  backup-root)    shift; cmd_backup_root "$@" ;;
  *)              sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
