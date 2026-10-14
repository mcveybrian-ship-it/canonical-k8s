#!/usr/bin/env bash
# =========================================================================================
# 07-kubernetes.sh - Canonical Kubernetes on the k8s guests (backlog B-07).
#
#   IMAGES - the cluster's own images, carried in and served by Harbor (decided 2026-10-14):
#     sudo ./07-kubernetes.sh images-export      MACHINE: stage-01 (online), refuses elsewhere.
#                                                the list from the PINNED snap's images.txt;
#                                                each image to an OCI layout under K8S_OCI_DIR,
#                                                plus images.lock - what was taken, by digest
#          ./07-kubernetes.sh images-load [dir]  MACHINE: whatever reaches Harbor with the
#                                                layouts on disk - stage-01 in the lab while the
#                                                gap cable is in; svc-harbor-01 in production,
#                                                after fetching svc-repo-01's /oci/ (runbook 4.5c)
#          ./07-kubernetes.sh images-check [dir] read-only, NO login: Harbor's digest for every
#                                                image in images.lock, read the way containerd
#                                                will read it
#
#   THE CLUSTER - MACHINE: the k8s guests (k8s-cp-01..03, k8s-wk-01..04), each hardened and
#   finished (03-compose-vm.sh --harden, then --finish), with this repo pushed to it:
#     sudo ./07-kubernetes.sh node-prep          EVERY node, first: kubelet's kernel settings,
#                                                snapd (FIPS), the FIPS base, then k8s side-loaded from the
#                                                mirror, containerd pointed at Harbor, and on a
#                                                control plane the API audit policy (K-A)
#     sudo ./07-kubernetes.sh bootstrap          k8s-cp-01 ONLY: the cluster, from a generated
#                                                config (Canonical's STIG file + this enclave)
#     sudo ./07-kubernetes.sh join-tokens        k8s-cp-01: one token FILE per other node, in the
#                                                operator's ~/k8s-join-tokens (0600, never printed)
#     sudo ./07-kubernetes.sh join               on the joining node: reads ~/k8s-join.token (copied
#                                                from cp-01 by stage-01, scp -3), joins as control
#                                                plane or worker by its address, shreds the file
#     sudo ./07-kubernetes.sh join-token <node>  on a control plane: ONE token, printed - by hand only
#          ./07-kubernetes.sh render             print the config THIS node would use; changes
#                                                nothing (needs the snap installed)
#     sudo ./07-kubernetes.sh verify             on a control plane: the cluster, FIPS in the
#                                                running processes, DNS, a dual-stack LoadBalancer
#                                                Service, the K-A audit policy. Leaves the test
#                                                workload (namespace enclave-verify) running
#     sudo ./07-kubernetes.sh verify --fips-only any node: only this node's processes' crypto
#     sudo ./07-kubernetes.sh verify --cleanup   remove the test workload
#
# WHERE THE IMAGES GO, AND WHY THE PROJECT IS NOT A PARAMETER
#
#   containerd on each node is told (hosts.d/ghcr.io/hosts.toml, Canonical's air-gap guide)
#   that ghcr.io is served by Harbor. It then asks Harbor for the SAME path it would have asked
#   ghcr.io for: ghcr.io/canonical/cilium:1.19.4-ck1 becomes a request for
#   /v2/canonical/cilium/manifests/1.19.4-ck1. Harbor reads the first path component as the
#   project. So the project is "canonical" because the snap's images say so - a different
#   name would need override_path on every node to undo it. Derived, not chosen.
#
#   The project is PUBLIC for reads (decided 2026-10-14): hosts.toml has no place for a
#   credential, and these are Canonical's public images. Pushing still needs the Harbor admin.
#
# WHY ONE PLATFORM (K8S_IMAGE_PLATFORM, decided 2026-10-14)
#
#   Upstream tags are multi-platform indexes (amd64 + arm64). Copying one platform keeps that
#   platform's manifest byte for byte - its digest is Canonical's own amd64 digest, proven on
#   stage-01 2026-10-14 against pause:3.10 - and roughly halves the transfer (~1 GB for the
#   twelve images of rev 5526). Empty copies every platform, and the digest is then the index's.
#
# THE CHAIN OF CUSTODY
#
#   export   records each upstream digest in images.lock as it copies
#   load     refuses a layout whose digest is not the one in images.lock, pushes, reads back
#   check    reads every image back from Harbor WITHOUT credentials and compares to the lock
#   Blobs are content-addressed, so a corrupted layer fails the push itself.
#
# CREDENTIALS: the Harbor admin password - environment HARBOR_ADMIN_PASSWORD > the site
#   credentials file (credentials.sh) > asked at the terminal. It is never on a command line:
#   regctl takes it on stdin and keeps its login in a private temporary HOME that is deleted
#   on exit, and curl reads it from a config on stdin.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENC="$(cd "$SELF/../enclave" && pwd)"
ADDRS="$ENC/enclave-addresses.env"
TPARAMS="$SELF/../transfer/transfer-params.env"
# shellcheck disable=SC1091
. "$ENC/credentials.sh"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

[ -r "$ADDRS" ] || die "no address file at $ADDRS"
# shellcheck disable=SC1090
. "$ADDRS"
# MIRROR_BASE lives in the transfer parameters on stage-01; elsewhere the default is the same path.
if [ -r "$TPARAMS" ]; then
  # shellcheck disable=SC1090
  . "$TPARAMS"
fi

# The revision is a DECISION (Q23, 2026-08-31: v1.36.4, rev 5526), not a discovery - side-loading
# pins it, and the images are whatever THAT revision's images.txt names.
K8S_SNAP_REV="${K8S_SNAP_REV:-5526}"
K8S_SNAP_DIR="${K8S_SNAP_DIR:-${MIRROR_BASE:-/srv/apt-mirror}/snaps}"
K8S_OCI_DIR="${K8S_OCI_DIR:-${MIRROR_BASE:-/srv/apt-mirror}/mirror/oci/k8s-${K8S_SNAP_REV}}"
K8S_IMAGE_PLATFORM="${K8S_IMAGE_PLATFORM-linux/amd64}"
K8S_UPSTREAM_REGISTRY="${K8S_UPSTREAM_REGISTRY:-ghcr.io}"   # the one registry hosts.d redirects
K8S_REGISTRY="${K8S_REGISTRY:-svc-harbor-01.${ENCLAVE_DOMAIN:?}}"
K8S_HARBOR_USER="${K8S_HARBOR_USER:-admin}"
# 'yes' lets images-export replace a layout whose tag Canonical has since moved. Off by default:
# a moved tag means the images in the gap are not the ones that were tested.
K8S_EXPORT_REPLACE="${K8S_EXPORT_REPLACE:-}"

LOCK_NAME='images.lock'

# ---- the cluster (B2) ------------------------------------------------------------------------
# The base snap is the FIPS one: core22 from fips-updates/stable (Q8, backlog 3.25). Its revision
# is pinned beside the k8s revision, and node-prep refuses a core22 that is not this one.
K8S_CORE22_REV="${K8S_CORE22_REV:-2383}"
# The snapd SNAP. Installing the first app snap on a newer base makes snapd install itself as a
# snap first - from the store, which the gap does not have (found on k8s-cp-01, 2026-10-14). Pinned
# like the others, and the FIPS build (decided by Brian 2026-10-14): snapd checks the signature on
# every snap it installs. fips-updates/stable was EMPTY that day; rev 28333 is 2.78+fips from
# fips-updates/candidate - the same channel class k8s rev 5526 came from. Q-CORE asks when stable.
K8S_SNAPD_REV="${K8S_SNAPD_REV:-28333}"
# Where the in-gap mirror serves the snaps and their assertions (runbook 4.1; direct URLs - the
# mirror lists no directories).
K8S_SNAP_URL="${K8S_SNAP_URL:-https://svc-repo-01.${ENCLAVE_DOMAIN}/snaps}"
# containerd's registry directory. /etc/containerd is what Canonical's STIG audit names
# (V-242405); bootstrap and join read containerd's ACTUAL config_path afterwards and refuse a
# mismatch rather than trust the documentation, which gives two different paths.
K8S_HOSTS_D="${K8S_HOSTS_D:-/etc/containerd/hosts.d}"
K8S_CONF_DIR="${K8S_CONF_DIR:-/var/snap/k8s/common/etc/configurations}"
K8S_AUDIT_POLICY="${K8S_AUDIT_POLICY:-$K8S_CONF_DIR/enclave-audit-policy.yaml}"
# Pod Security (K-C, 2026-10-14): Canonical's baseline file, shipped in the snap.
K8S_PSA_FILE="${K8S_PSA_FILE:-$K8S_CONF_DIR/pod-security-admission-baseline.yaml}"
K8S_API_NAME="${K8S_API_NAME:-k8s-api.${ENCLAVE_DOMAIN}}"
# The enclave DNS (svc-mgmt-01). CoreDNS would otherwise forward to the node's resolv.conf, which
# is systemd-resolved's 127.0.0.53 - a loopback address that means nothing inside a pod.
K8S_UPSTREAM_DNS="${K8S_UPSTREAM_DNS:-${SVC_MGMT_01:-}}"
K8S_WAIT="${K8S_WAIT:-15m}"
# JOIN TOKENS TRAVEL AS FILES (Brian, 2026-10-14): printed tokens land in terminal scrollback and
# the clipboard, and a pasted placeholder was once sent as a token. cp-01 writes one file per node
# into the operator's home (the operator's own ownership, so stage-01 can scp -3 it straight to
# the node); the node reads its file, joins, and shreds it. Single-use and bound to a node name.
K8S_OPERATOR="${SUDO_USER:-$(id -un)}"
K8S_OPERATOR_HOME="$(getent passwd "$K8S_OPERATOR" | cut -d: -f6)"
K8S_TOKEN_DIR="${K8S_TOKEN_DIR:-$K8S_OPERATOR_HOME/k8s-join-tokens}"
K8S_TOKEN_FILE="${K8S_TOKEN_FILE:-$K8S_OPERATOR_HOME/k8s-join.token}"
CA_ROOT="${CA_ROOT:-$ENC/trust-anchors/enclave-root.crt}"

# regctl gets a private HOME: its login lands there and dies with it, and root's or the
# operator's own registry logins are never used by accident. A second, EMPTY home is the
# anonymous reader for images-check - what containerd will be.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -m 700 "$WORK/home" "$WORK/anon"
rc_auth() { HOME="$WORK/home" command regctl "$@"; }
rc_anon() { HOME="$WORK/anon" command regctl "$@"; }

need_tools() {
  local t
  for t in "$@"; do command -v "$t" >/dev/null || die "$t not found - it is Stage-B tooling (runbook 4.5c); in the gap, /bin/ on svc-repo-01"; done
}

# ghcr.io/canonical/cilium:1.19.4-ck1 -> canonical/cilium   (the path, no registry, no tag)
img_path() { local r="${1#*/}"; printf '%s' "${r%:*}"; }
img_tag()  { printf '%s' "${1##*:}"; }
img_reg()  { printf '%s' "${1%%/*}"; }

plat_args() { [ -n "$K8S_IMAGE_PLATFORM" ] && printf -- '--platform\n%s\n' "$K8S_IMAGE_PLATFORM"; return 0; }

# The lock, as "ref digest" lines. Refuses a missing or empty one - a load with nothing to
# compare against is not a load.
read_lock() {
  local dir="$1" body
  [ -r "$dir/$LOCK_NAME" ] || die "no $LOCK_NAME in $dir - was images-export run, and is this the directory it wrote?"
  body="$(grep -vE '^[[:space:]]*(#|$)' "$dir/$LOCK_NAME" || true)"
  [ -n "$body" ] || die "$dir/$LOCK_NAME lists no images"
  printf '%s\n' "$body" | awk 'NF!=2 {exit 1}' || die "$dir/$LOCK_NAME has a line that is not 'image digest'"
  printf '%s\n' "$body"
}

# ---- images-export ------------------------------------------------------------------------
cmd_images_export() {
  need_root
  need_tools regctl unsquashfs sha256sum
  # WHERE: the staging machine, by address - the same rule as 06a: never a typed name.
  local mine; mine="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  printf '%s\n' "$mine" | grep -qx "${STAGE_01:?no STAGE_01 in $ADDRS}" \
    || die "this machine ($(hostname -s)) does not hold STAGE_01 ($STAGE_01) - images-export runs on the online staging machine only"

  local snap="$K8S_SNAP_DIR/k8s_${K8S_SNAP_REV}.snap"
  [ -r "$snap" ] || die "no $snap - the pinned snap is not staged here"
  [ -r "${snap%.snap}.assert" ] || die "no ${snap%.snap}.assert beside the snap - it would not side-load in the gap either"

  local list; list="$(unsquashfs -cat "$snap" images.txt)" || die "could not read images.txt from $snap"
  local n; n="$(printf '%s\n' "$list" | grep -c .)"
  local snapsum; snapsum="$(sha256sum "$snap" | cut -c1-64)"
  say "snap        k8s rev $K8S_SNAP_REV  sha256 ${snapsum:0:16}...  ($n images in its images.txt)"
  say "platform    ${K8S_IMAGE_PLATFORM:-all (whole index)}"
  say "into        $K8S_OCI_DIR"
  echo

  local r bad=""
  for r in $list; do
    [ "$(img_reg "$r")" = "$K8S_UPSTREAM_REGISTRY" ] \
      || bad="$bad $r"
  done
  [ -z "$bad" ] || die "image(s) not on $K8S_UPSTREAM_REGISTRY:$bad
      Each upstream registry needs its own hosts.d entry on every node and its own path rule
      here. Neither exists - extend both before carrying these."

  mkdir -p "$K8S_OCI_DIR"
  local lock="$WORK/lock" up have dst copied=0 kept=0 moved=""
  : > "$lock"
  # shellcheck disable=SC2046
  for r in $list; do
    dst="ocidir://$K8S_OCI_DIR/$(img_path "$r"):$(img_tag "$r")"
    up="$(rc_auth image digest $(plat_args) "$r")" || die "could not read $r from $K8S_UPSTREAM_REGISTRY"
    have=""
    # A layout that is not there yet is the normal first run; one that IS there and cannot
    # be read is a fault, and its error is shown rather than mistaken for "not there".
    if [ -e "$K8S_OCI_DIR/$(img_path "$r")/index.json" ]; then
      have="$(rc_auth image digest "$dst" 2>&1)" || die "$r: a layout exists but cannot be read: $have"
    fi
    if [ "$have" = "$up" ]; then
      printf '  %-58s %s  already exported - unchanged\n' "$r" "${up:7:12}"
      kept=$((kept + 1))
    else
      if [ -n "$have" ] && [ "$K8S_EXPORT_REPLACE" != yes ]; then
        moved="$moved
      $r  local ${have:7:12}  upstream now ${up:7:12}"
        continue
      fi
      rc_auth image copy $(plat_args) "$r" "$dst" >/dev/null || die "copy failed: $r"
      have="$(rc_auth image digest "$dst")"
      [ "$have" = "$up" ] || die "$r: the layout's digest ${have:7:12} is not upstream's ${up:7:12} - not recording it"
      printf '  %-58s %s  exported\n' "$r" "${up:7:12}"
      copied=$((copied + 1))
    fi
    printf '%s %s\n' "$r" "$up" >> "$lock"
  done
  [ -z "$moved" ] || die "Canonical has MOVED these tags since they were exported:$moved
      The images in the gap would no longer be the ones tested. Find out why before replacing
      them; to take the new ones: sudo K8S_EXPORT_REPLACE=yes $0 images-export"

  { printf '# %s - 07-kubernetes.sh images-export, %s on %s\n' "$LOCK_NAME" "$(date -u +%FT%TZ)" "$(hostname -s)"
    printf '# snap k8s rev %s (sha256 %s), platform %s, %s images\n' "$K8S_SNAP_REV" "$snapsum" "${K8S_IMAGE_PLATFORM:-all}" "$n"
    printf '# Each line: the image as the snap names it, then the manifest digest exported for it.\n'
    cat "$lock"; } > "$K8S_OCI_DIR/$LOCK_NAME.new"
  mv "$K8S_OCI_DIR/$LOCK_NAME.new" "$K8S_OCI_DIR/$LOCK_NAME"
  # nginx on svc-repo-01 serves this tree as www-data; root-only files would be a 403 there.
  chmod -R a+rX "$K8S_OCI_DIR"

  echo
  ok "$n images: $copied exported, $kept already there  ($(du -sh "$K8S_OCI_DIR" | cut -f1) on disk)"
  ok "$K8S_OCI_DIR/$LOCK_NAME written"
  say "the mirror's oci/ tree crosses with every transfer (restore-mirror.sh) - nothing new to carry"
}

# ---- Harbor: login and the project --------------------------------------------------------
HPW=""
harbor_password() {
  [ -n "$HPW" ] && return 0
  HPW="${HARBOR_ADMIN_PASSWORD:-}"
  if [ -z "$HPW" ]; then
    cred_require_safe
    HPW="$(cred_get HARBOR_ADMIN_PASSWORD)"
  fi
  if [ -z "$HPW" ]; then
    [ -r /dev/tty ] || die "no HARBOR_ADMIN_PASSWORD in the environment or the credentials file, and no terminal to ask on"
    read -rsp "  Harbor password for $K8S_HARBOR_USER@$K8S_REGISTRY: " HPW < /dev/tty; echo
  fi
  [ -n "$HPW" ] || die "no Harbor password given"
}

# harbor_api METHOD PATH [JSON] -> HTTP code on stdout, body in $WORK/api.out. The credential
# goes to curl as a config on stdin, never as an argument.
harbor_api() {
  local m="$1" p="$2" d="${3:-}" pw="${HPW//\\/\\\\}"
  pw="${pw//\"/\\\"}"
  local args=(-sS -K - -X "$m" -o "$WORK/api.out" -w '%{http_code}' -H 'Content-Type: application/json'
              -H 'X-Is-Resource-Name: true')
  [ -n "$d" ] && args+=(--data "$d")
  printf 'user = "%s:%s"\n' "$K8S_HARBOR_USER" "$pw" | curl "${args[@]}" "https://$K8S_REGISTRY/api/v2.0$p"
}

ensure_project() {
  local proj="$1" code pub
  code="$(harbor_api GET "/projects/$proj")" || die "Harbor API unreachable at $K8S_REGISTRY"
  case "$code" in
    200) ;;
    404)
      code="$(harbor_api POST /projects "{\"project_name\":\"$proj\",\"metadata\":{\"public\":\"true\",\"auto_scan\":\"true\"}}")"
      [ "$code" = 201 ] || die "creating project $proj: HTTP $code - $(head -c 300 "$WORK/api.out")"
      ok "project $proj created - public read, scan on push"
      return 0 ;;
    401) die "Harbor refused the login for $K8S_HARBOR_USER (HTTP 401)" ;;
    *)   die "looking up project $proj: HTTP $code - $(head -c 300 "$WORK/api.out")" ;;
  esac
  pub="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("metadata",{}).get("public",""))' "$WORK/api.out")"
  if [ "$pub" = true ]; then
    ok "project $proj already public - unchanged"
  else
    code="$(harbor_api PUT "/projects/$proj" '{"metadata":{"public":"true"}}')"
    [ "$code" = 200 ] || die "making project $proj public: HTTP $code - $(head -c 300 "$WORK/api.out")"
    ok "project $proj made public (it was: ${pub:-unset}) - containerd has no credential to offer"
  fi
}

# ---- images-load --------------------------------------------------------------------------
cmd_images_load() {
  local dir="${1:-$K8S_OCI_DIR}"
  need_tools regctl curl python3
  local entries; entries="$(read_lock "$dir")"
  local projects; projects="$(printf '%s\n' "$entries" | awk '{print $1}' | while read -r r; do img_path "$r" | cut -d/ -f1; done | sort -u)"
  say "from        $dir  ($(printf '%s\n' "$entries" | grep -c .) images in $LOCK_NAME)"
  say "into        $K8S_REGISTRY  project(s): $(printf '%s' "$projects" | tr '\n' ' ')"
  echo

  # Every layout is checked against the lock BEFORE anything is pushed: a half-loaded
  # registry is worse than an unloaded one.
  local r want have
  while read -r r want; do
    have="$(rc_anon image digest "ocidir://$dir/$(img_path "$r"):$(img_tag "$r")" 2>&1)" \
      || die "$r: no readable layout in $dir ($have)"
    [ "$have" = "$want" ] || die "$r: the layout on disk is ${have:7:12}, $LOCK_NAME says ${want:7:12} - refusing to load any of it"
  done <<< "$entries"
  ok "all layouts match $LOCK_NAME"

  harbor_password
  printf '%s' "$HPW" | rc_auth registry login "$K8S_REGISTRY" -u "$K8S_HARBOR_USER" --pass-stdin >/dev/null \
    || die "regctl could not log in to $K8S_REGISTRY as $K8S_HARBOR_USER"
  local p
  for p in $projects; do ensure_project "$p"; done

  local tgt now pushed=0 kept=0
  while read -r r want; do
    tgt="$K8S_REGISTRY/$(img_path "$r"):$(img_tag "$r")"
    # Not there yet is normal; the reason is kept so a push that then fails can show it.
    now="$(rc_auth image digest "$tgt" 2>"$WORK/err" || true)"
    if [ "$now" = "$want" ]; then
      printf '  %-58s %s  already in Harbor - unchanged\n' "$tgt" "${want:7:12}"
      kept=$((kept + 1)); continue
    fi
    rc_auth image copy "ocidir://$dir/$(img_path "$r"):$(img_tag "$r")" "$tgt" >/dev/null \
      || die "push failed: $tgt (before it, Harbor said: $(tail -1 "$WORK/err"))"
    now="$(rc_auth image digest "$tgt")"
    [ "$now" = "$want" ] || die "$tgt: Harbor now serves ${now:7:12}, not ${want:7:12}"
    printf '  %-58s %s  pushed\n' "$tgt" "${want:7:12}"
    pushed=$((pushed + 1))
  done <<< "$entries"
  rc_auth registry logout "$K8S_REGISTRY" >/dev/null 2>&1 || true
  echo
  ok "$pushed pushed, $kept already there - next: $0 images-check${1:+ $1}"
}

# ---- images-check -------------------------------------------------------------------------
cmd_images_check() {
  local dir="${1:-$K8S_OCI_DIR}"
  need_tools regctl
  local entries; entries="$(read_lock "$dir")"
  say "reading $K8S_REGISTRY with NO credentials - the way containerd will"
  echo
  local r want have tgt fail=0 n=0
  while read -r r want; do
    n=$((n + 1))
    tgt="$K8S_REGISTRY/$(img_path "$r"):$(img_tag "$r")"
    if ! have="$(rc_anon image digest "$tgt" 2>&1)"; then
      printf '  [x] %-58s NOT READABLE: %s\n' "$tgt" "$(printf '%s' "$have" | tail -1)"; fail=$((fail + 1))
    elif [ "$have" != "$want" ]; then
      printf '  [x] %-58s %s  lock says %s\n' "$tgt" "${have:7:12}" "${want:7:12}"; fail=$((fail + 1))
    else
      printf '  [ok] %-57s %s\n' "$tgt" "${have:7:12}"
    fi
  done <<< "$entries"
  echo
  [ "$fail" -eq 0 ] || die "$fail of $n images missing or different in Harbor"
  ok "all $n images in Harbor, readable anonymously, digests match $LOCK_NAME"
}

# ===================================================================== B2 - the cluster
# WHICH k8s node this is, from its address - never a typed name (the 05/06a rule).
ME=""; ME_ADDR=""; ME_ROLE=""; ME_ADDR6=""
whoami_k8s() {
  local k a mine
  mine="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  for k in $(grep -oE '^K8S_(CP|WK)_[0-9]+=' "$ADDRS" | tr -d '='); do
    a="${!k:-}"
    if [ -n "$a" ] && printf '%s\n' "$mine" | grep -qx "$a"; then
      ME="$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')"; ME_ADDR="$a"
      case "$k" in K8S_CP_*) ME_ROLE='cp' ;; *) ME_ROLE='wk' ;; esac
      ME_ADDR6="$(node_v6 "$a")"
      return 0
    fi
  done
  die "this machine ($(hostname -s)) holds no K8S_CP_*/K8S_WK_* address in $ADDRS - this runs on the k8s nodes only"
}
# The IPv6 rule, the same one 03-compose-vm.sh writes into the guest: prefix + the IPv4 last octet.
node_v6() {
  case "${K8S_NODE_V6_NET:-}" in
    *::/64) printf '%s::%s' "${K8S_NODE_V6_NET%::/64}" "${1##*.}" ;;
    *) die "K8S_NODE_V6_NET='${K8S_NODE_V6_NET:-}' is not <prefix>::/64 - the cluster is dual-stack (B-07 A2)" ;;
  esac
}

# Kubelet's --protect-kernel-defaults REFUSES to start unless these are already set (Canonical's
# STIG how-to, fetched 2026-10-14). The values are kubelet's, not a tuning choice.
KUBELET_SYSCTL="vm.overcommit_memory=1
vm.panic_on_oom=0
kernel.keys.root_maxbytes=25000000
kernel.keys.root_maxkeys=1000000
kernel.panic=10
kernel.panic_on_oops=1"
KUBELET_SYSCTL_FILE="${KUBELET_SYSCTL_FILE:-/etc/sysctl.d/99-kubelet.conf}"

# K-A (decided 2026-10-14): a NARROW, DOCUMENTED deviation from V-242403. The STIG's check wants
# exactly `- level: RequestResponse` for everything, which writes every Secret's VALUE into the
# API audit log - and that log is offloaded to svc-obs-01 and backed up from there to the vault
# and the NAS. So: Secrets, token requests and token reviews at Metadata (who, what, when, the
# result - not the value); everything else at RequestResponse, as the STIG asks. First match wins.
audit_policy() {
cat <<'EOF'
# enclave-audit-policy.yaml - written by 07-kubernetes.sh node-prep (backlog B-07, decision K-A).
# V-242403 deviation, documented: Secrets and service-account tokens at Metadata, so their
# values never reach the audit log or its copies; every other request at RequestResponse.
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "serviceaccounts/token"]
      - group: "authentication.k8s.io"
        resources: ["tokenreviews"]
  - level: RequestResponse
EOF
}

# containerd: ghcr.io is served by Harbor, over TLS from the enclave CA. No credential - the
# project is public for reads (decided 2026-10-14).
hosts_toml() {
cat <<EOF
# written by 07-kubernetes.sh node-prep (B-07) - ghcr.io's images come from Harbor, never the internet
[host."https://${K8S_REGISTRY}"]
  capabilities = ["pull", "resolve"]
  ca = "${K8S_HOSTS_D}/${K8S_UPSTREAM_REGISTRY}/ca.crt"
EOF
}

# install_if_changed DEST MODE - stdin to DEST, only when the content differs; says which.
install_if_changed() {
  local dest="$1" mode="$2" tmp="$WORK/install.new"
  cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then ok "$dest already in place - unchanged"; return 0; fi
  install -D -o root -g root -m "$mode" "$tmp" "$dest"; ok "$dest written"
}

# `snap list NAME` EXITS 1 for a snap that is not installed - the normal first-run case. Under
# set -e and pipefail that ended node-prep SILENTLY on k8s-cp-01 (2026-10-14), so "not installed"
# is an empty answer here, never a failure.
snap_rev() { { snap list "$1" 2>/dev/null || true; } | awk 'NR==2 {print $3}'; }
snap_ver() { { snap list "$1" 2>/dev/null || true; } | awk 'NR==2 {print $2}'; }

# side_load NAME REV [--classic] - from the mirror, verified by snapd against Canonical's signed
# assertion (snap ack, then the install of a file whose hash that assertion names). Downloaded
# into this run's private WORK directory, which the EXIT trap removes.
side_load() {
  local name="$1" rev="$2" extra="${3:-}" f have
  have="$(snap_rev "$name")"
  if [ "$have" = "$rev" ]; then ok "$name rev $rev already installed - unchanged"; return 0; fi
  [ -z "$have" ] || die "$name is installed at rev $have, not $rev - refusing to replace it here; remove it deliberately first"
  mkdir -p "$WORK/snaps"
  for f in "${name}_${rev}.assert" "${name}_${rev}.snap"; do
    curl -fsS --cacert "$CA_ROOT" -o "$WORK/snaps/$f" "$K8S_SNAP_URL/$f" || die "could not fetch $K8S_SNAP_URL/$f"
  done
  snap ack "$WORK/snaps/${name}_${rev}.assert" || die "snap ack refused ${name}_${rev}.assert"
  # shellcheck disable=SC2086  # $extra is empty or exactly --classic
  snap install "$WORK/snaps/${name}_${rev}.snap" $extra || die "snap install of ${name}_${rev}.snap failed"
  have="$(snap_rev "$name")"
  [ "$have" = "$rev" ] || die "$name installed, but as rev $have, not $rev - the assertion did not match"
  ok "$name rev $rev side-loaded, verified against its signed assertion"
}

cmd_node_prep() {
  need_root
  whoami_k8s
  say "node        $ME ($ME_ADDR, $ME_ADDR6) - $( [ "$ME_ROLE" = cp ] && echo control plane || echo worker)"
  echo
  [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = 1 ] \
    || die "the kernel is not in FIPS mode (/proc/sys/crypto/fips_enabled != 1) - this node was not hardened (05 fips)"
  ip -6 -o addr show scope global | grep -q " ${ME_ADDR6}/64 " \
    || die "$ME does not hold $ME_ADDR6/64 - composed before the dual-stack change? (03-compose-vm.sh, B-07 B1)"
  ok "FIPS kernel, and both addresses present"

  # 1. kubelet's kernel settings, then READ BACK: a later file in sysctl.d silently wins.
  printf '%s\n' "# kubelet --protect-kernel-defaults (Canonical's DISA STIG how-to) - 07-kubernetes.sh node-prep" "$KUBELET_SYSCTL" \
    | install_if_changed "$KUBELET_SYSCTL_FILE" 0644
  sysctl --system >/dev/null
  local kv k v now bad=""
  while IFS= read -r kv; do
    k="${kv%%=*}"; v="${kv#*=}"; now="$(sysctl -n "$k")"
    [ "$now" = "$v" ] || bad="$bad $k=$now (want $v; set by: $({ grep -ls "^[[:space:]]*$k" /etc/sysctl.d/* /run/sysctl.d/* /usr/lib/sysctl.d/* /etc/sysctl.conf 2>/dev/null || true; } | tr '\n' ' '))"
  done <<< "$KUBELET_SYSCTL"
  [ -z "$bad" ] || die "kernel settings kubelet requires are overridden:$bad"
  ok "kubelet's six kernel settings live"

  # 2. snapd as a snap (FIPS), then the FIPS base, then k8s. Each missing one would otherwise send
  #    snapd to the store, and there is no store: k8s needs the snapd snap (found 2026-10-14) and
  #    takes its cryptography from core22 (3.25).
  [ -r "$CA_ROOT" ] || die "no enclave root at $CA_ROOT"
  side_load snapd "$K8S_SNAPD_REV"
  case "$(snap_ver snapd)" in
    *fips*) ok "snapd is the FIPS build: $(snap_ver snapd), rev $(snap_rev snapd)" ;;
    *) die "snapd rev $(snap_rev snapd) is version $(snap_ver snapd) - not a +fips build (decided 2026-10-14)" ;;
  esac
  side_load core22 "$K8S_CORE22_REV"
  case "$(snap_ver core22)" in
    *fips*) ok "core22 is the FIPS build: $(snap_ver core22), rev $(snap_rev core22)" ;;
    *) die "core22 rev $(snap_rev core22) is version $(snap_ver core22) - not a +fips build (backlog 3.25)" ;;
  esac
  side_load k8s "$K8S_SNAP_REV" --classic
  # No store to refresh from, and a revision that moved by itself would not be the one tested.
  if snap refresh --hold snapd core22 k8s >/dev/null 2>&1; then ok "refresh held for snapd, core22 and k8s"
  else warn "snap refresh --hold failed - check 'snap refresh --time'"; fi

  # 3. containerd: ghcr.io from Harbor, trusting the enclave root.
  install_if_changed "$K8S_HOSTS_D/$K8S_UPSTREAM_REGISTRY/ca.crt" 0644 < "$CA_ROOT"
  hosts_toml | install_if_changed "$K8S_HOSTS_D/$K8S_UPSTREAM_REGISTRY/hosts.toml" 0644
  local code
  code="$(curl -sS --cacert "$CA_ROOT" -o /dev/null -w '%{http_code}' "https://$K8S_REGISTRY/v2/" 2>&1)" || true
  case "$code" in
    200|401) ok "Harbor answers over TLS with the enclave root (/v2/ -> $code)" ;;
    *) die "cannot reach https://$K8S_REGISTRY/v2/ over TLS with the enclave root: $code" ;;
  esac

  # 4. control planes: the API audit policy (K-A) - it must exist before the API server starts.
  if [ "$ME_ROLE" = cp ]; then
    audit_policy | install_if_changed "$K8S_AUDIT_POLICY" 0600
    [ -r "$K8S_PSA_FILE" ] || die "no Pod Security file at $K8S_PSA_FILE - is this snap rev $K8S_SNAP_REV?"
  fi
  echo
  if [ "$ME" = k8s-cp-01 ]; then ok "$ME prepared - next: sudo $0 bootstrap"
  else ok "$ME prepared - next: a token from k8s-cp-01 (sudo $0 join-token $ME), then sudo $0 join <token>"; fi
}

# The STIG arguments come from the SNAP'S OWN file for this revision (Canonical's
# k8s/resources/configurations/disa-stig/<file>), so a new revision brings its own. Two of them are
# REPLACED by enclave decisions: --audit-policy-file (K-A) and --admission-control-config-file
# (K-C, the same baseline file, named explicitly). Everything else is taken as Canonical wrote it.
stig_file() { printf '/snap/k8s/current/k8s/resources/configurations/disa-stig/%s.yaml' "$1"; }

# render_config KIND -> the config for this node. KIND: bootstrap | control-plane | worker
render_config() {
  local kind="$1" src; src="$(stig_file "$kind")"
  [ -r "$src" ] || die "no $src - node-prep first (it installs the snap)"
  printf '# %s - generated by 07-kubernetes.sh for %s, %s\n' "$kind" "$ME" "$(date -u +%FT%TZ)"
  printf '# STIG arguments from %s (snap rev %s); enclave decisions marked.\n' "$src" "$K8S_SNAP_REV"
  if [ "$kind" = bootstrap ]; then
    # Both families, set ONCE here and never changeable (enclave-addresses.env, B-07 A2).
    printf 'pod-cidr: "%s,%s"\n' "${K8S_POD_CIDR_V4:?}" "${K8S_POD_CIDR_V6:?}"
    printf 'service-cidr: "%s,%s"\n' "${K8S_SERVICE_CIDR_V4:?}" "${K8S_SERVICE_CIDR_V6:?}"
    printf 'extra-sans:\n  - "%s"\n  - "%s"\n' "${K8S_API_VIP:?}" "$K8S_API_NAME"
    printf 'control-plane-taints:\n  - "node-role.kubernetes.io/control-plane:NoSchedule"   # H3: no app pods on control planes\n'
    printf 'cluster-config:\n'
    printf '  network:\n    enabled: true\n'
    printf '  dns:\n    enabled: true\n    upstream-nameservers:\n      - "%s"   # the enclave DNS, not the node resolver 127.0.0.53\n' "${K8S_UPSTREAM_DNS:?}"
    printf '  local-storage:\n    enabled: false   # node-local volumes do not survive their node; Ceph is B-08\n'
    printf '  gateway:\n    enabled: true    # Gateway API, decided 2026-10-02\n'
    printf '  ingress:\n    enabled: false\n'
    printf '  load-balancer:\n    enabled: true\n    l2-mode: true\n    cidrs:\n      - "%s-%s"\n      - "%s-%s"\n' \
      "${K8S_LB_POOL_START:?}" "${K8S_LB_POOL_END:?}" "${K8S_LB_POOL_V6_START:?}" "${K8S_LB_POOL_V6_END:?}"
    printf '  metrics-server:\n    enabled: true\n'
  fi
  # The per-node argument blocks: Canonical's lines, two replaced, and --node-ip added.
  awk -v audit="$K8S_AUDIT_POLICY" -v psa="$K8S_PSA_FILE" -v nodeip="$ME_ADDR,$ME_ADDR6" '
    /^extra-node-[a-z-]+-args:/ { blk = $1; print
                                  if (blk == "extra-node-kubelet-args:") print "  --node-ip: \"" nodeip "\"   # both families (B-07 A2)"
                                  next }
    /^[^ ]/ { blk = ""; next }
    blk != "" && /^  --audit-policy-file:/ { print "  --audit-policy-file: " audit "   # K-A: the enclave policy"; next }
    blk != "" && /^  --admission-control-config-file:/ { print "  --admission-control-config-file: " psa "   # K-C: baseline"; next }
    blk != "" { print }' "$src"
}

cmd_render() {
  whoami_k8s
  local kind
  if [ "$ME" = k8s-cp-01 ]; then kind=bootstrap; elif [ "$ME_ROLE" = cp ]; then kind=control-plane; else kind=worker; fi
  render_config "$kind"
}

# After bootstrap or join: where containerd ACTUALLY reads registry config, against where
# node-prep wrote it. A mismatch means every pull goes to ghcr.io - which fails in the gap.
check_containerd_path() {
  local f got=""
  for f in /etc/containerd/config.toml /var/snap/k8s/common/etc/containerd/config.toml; do
    [ -r "$f" ] || continue
    got="$(sed -n 's/^[[:space:]]*config_path[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$f" | head -1)"
    [ -z "$got" ] || break
  done
  [ -n "$got" ] || die "found no containerd config_path - cannot prove images come from Harbor. Look: sudo grep -rn config_path /etc/containerd /var/snap/k8s/common/etc"
  [ "$got" = "$K8S_HOSTS_D" ] || die "containerd reads registry config from $got, node-prep wrote $K8S_HOSTS_D - set K8S_HOSTS_D=$got and re-run node-prep"
  ok "containerd reads registry config from $got - where node-prep wrote ghcr.io -> Harbor"
}

cmd_bootstrap() {
  need_root
  whoami_k8s
  [ "$ME" = k8s-cp-01 ] || die "bootstrap runs on k8s-cp-01 only - every other node joins (sudo $0 join <token>)"
  [ -x /snap/bin/k8s ] || die "no k8s snap - run node-prep first"
  if /snap/bin/k8s status >/dev/null 2>&1; then ok "a cluster is already bootstrapped here - nothing to do"; /snap/bin/k8s status; return 0; fi
  [ -r "$K8S_AUDIT_POLICY" ] || die "no audit policy at $K8S_AUDIT_POLICY - run node-prep first"
  local cfg="$K8S_CONF_DIR/enclave-bootstrap.yaml"
  render_config bootstrap | install_if_changed "$cfg" 0600
  say "the config:"; sed 's/^/      /' "$cfg"; echo
  # --address: these guests have NO default route, so "the IP of the default-route interface"
  # has nothing to find. Always explicit.
  /snap/bin/k8s bootstrap --file "$cfg" --address "$ME_ADDR" --timeout "$K8S_WAIT" || die "k8s bootstrap failed - read the output above"
  # BEFORE waiting for ready: with the wrong registry path every image pull fails, and the wait
  # would burn its whole timeout before saying anything.
  check_containerd_path
  /snap/bin/k8s status --wait-ready --timeout "$K8S_WAIT" || die "the cluster did not become ready within $K8S_WAIT"
  echo
  ok "cluster bootstrapped on $ME - next, for each other node: sudo $0 join-token <node> HERE, then join THERE"
}

# A join token, checked for shape before k8s sees it: one line, no spaces, long. A pasted
# placeholder reached k8s on 2026-10-14 and came back as an unexplained "EOF" from k8sd.
token_ok() { [ "${#1}" -ge 40 ] && [[ "$1" =~ ^[A-Za-z0-9+/=_.-]+$ ]]; }

# Every node but this one, from the address file - so a fifth worker needs no edit here.
other_nodes() {
  local k n
  for k in $(grep -oE '^K8S_(CP|WK)_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do
    n="$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')"
    [ "$n" = "$ME" ] || printf '%s\n' "$n"
  done
}

cmd_join_tokens() {
  need_root
  whoami_k8s
  [ "$ME_ROLE" = cp ] || die "join tokens are issued by a control plane"
  if [ -z "$K8S_OPERATOR_HOME" ] || [ ! -d "$K8S_OPERATOR_HOME" ]; then die "no home directory for $K8S_OPERATOR"; fi
  install -d -m 0700 -o "$K8S_OPERATOR" -g "$K8S_OPERATOR" "$K8S_TOKEN_DIR"
  local n t f made=0
  for n in $(other_nodes); do
    f="$K8S_TOKEN_DIR/$n.token"
    case "$n" in k8s-wk-*) t="$(/snap/bin/k8s get-join-token "$n" --worker)" ;; *) t="$(/snap/bin/k8s get-join-token "$n")" ;; esac \
      || die "k8s get-join-token $n failed"
    t="$(printf '%s' "$t" | tr -d '[:space:]')"
    token_ok "$t" || die "k8s returned something that is not a token for $n - nothing written for it"
    printf '%s\n' "$t" > "$WORK/token"
    install -m 0600 -o "$K8S_OPERATOR" -g "$K8S_OPERATOR" "$WORK/token" "$f"
    ok "$f  (${#t} characters, 0600 $K8S_OPERATOR)"
    made=$((made + 1))
  done
  echo
  ok "$made token file(s) in $K8S_TOKEN_DIR - not printed. Next, from stage-01: copy each to its node (scp -3), then shred this directory"
}

cmd_join_token() {
  need_root
  whoami_k8s
  [ "$ME_ROLE" = cp ] || die "join tokens are issued by a control plane"
  local node="${1:-}"
  case "$node" in
    k8s-cp-0[0-9]) /snap/bin/k8s get-join-token "$node" ;;
    k8s-wk-0[0-9]) /snap/bin/k8s get-join-token "$node" --worker ;;
    *) die "usage: join-token <k8s-cp-0N|k8s-wk-0N> - the node's hostname, which the token is bound to" ;;
  esac
}

cmd_join() {
  need_root
  whoami_k8s
  local token="${1:-}" kind cfg from=""
  if [ -z "$token" ]; then
    [ -r "$K8S_TOKEN_FILE" ] || die "no token given and no $K8S_TOKEN_FILE - copy it from cp-01 first (stage-01, scp -3)"
    token="$(tr -d '[:space:]' < "$K8S_TOKEN_FILE")"; from="$K8S_TOKEN_FILE"
  fi
  token_ok "$token" || die "that is not a join token (${#token} characters) - a placeholder, or a truncated copy?"
  [ "$ME" != k8s-cp-01 ] || die "k8s-cp-01 bootstraps; it does not join"
  [ -x /snap/bin/k8s ] || die "no k8s snap - run node-prep first"
  if /snap/bin/k8s status >/dev/null 2>&1; then ok "$ME is already in a cluster - nothing to do"; return 0; fi
  if [ "$ME_ROLE" = cp ]; then
    kind=control-plane
    [ -r "$K8S_AUDIT_POLICY" ] || die "no audit policy at $K8S_AUDIT_POLICY - run node-prep first"
  else kind=worker; fi
  cfg="$K8S_CONF_DIR/enclave-$kind.yaml"
  render_config "$kind" | install_if_changed "$cfg" 0600
  say "the config:"; sed 's/^/      /' "$cfg"; echo
  /snap/bin/k8s join-cluster --file "$cfg" --address "$ME_ADDR" --timeout "$K8S_WAIT" "$token" \
    || die "k8s join-cluster failed - read the output above${from:+ ($from kept for the retry)}"
  check_containerd_path
  # Single-use and spent now: the file goes, so no copy of a cluster credential is left lying about.
  if [ -n "$from" ]; then shred -u "$from" && ok "$from shredded - the token is spent"; fi
  ok "$ME joined as a $kind"
}

# ===================================================================== B3 - verify
# Every check prints [ok] or [x]; the run fails if any [x] was printed. Re-runnable.
V_NS="${V_NS:-enclave-verify}"
V_PASS=0; V_FAIL=0
vok()  { printf '  [ok] %s\n' "$*"; V_PASS=$((V_PASS + 1)); }
vbad() { printf '  [x]  %s\n' "$*"; V_FAIL=$((V_FAIL + 1)); }
kc()   { /snap/bin/k8s kubectl "$@"; }

# FIPS IN THE RUNNING PROCESSES - what Canonical's FIPS guide does not check (it reads only
# /proc/sys/crypto/fips_enabled). The FIPS base snap carries libcrypto.so.3 and the OpenSSL FIPS
# provider, ossl-modules-3/fips.so. A process using the validated module has BOTH mapped, from
# /snap/core22/<rev>. Read from /proc/<pid>/maps, which needs root.
verify_fips_node() {
  local name pid maps lib fips
  if [ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = 1 ]; then vok "kernel in FIPS mode"; else vbad "kernel NOT in FIPS mode"; fi
  case "$(snap_ver core22)" in *fips*) vok "core22 $(snap_ver core22) rev $(snap_rev core22)" ;; *) vbad "core22 is $(snap_ver core22) - not +fips" ;; esac
  for name in kube-apiserver kube-controller-manager kube-scheduler kubelet etcd k8sd containerd k8s-apiserver-proxy; do
    pid="$(pgrep -f "^/snap/k8s/[^ ]*/bin/$name( |$)" | head -1 || true)"
    [ -n "$pid" ] || continue
    maps="$(awk '$6 ~ /libcrypto|fips\.so/ {print $6}' "/proc/$pid/maps" 2>/dev/null | sort -u)"
    lib="$(printf '%s\n' "$maps" | grep libcrypto | head -1 || true)"
    fips="$(printf '%s\n' "$maps" | grep 'fips\.so' | head -1 || true)"
    if [ -n "$fips" ] && [ "${fips#/snap/core22/}" != "$fips" ]; then
      vok "$name (pid $pid): $lib + $fips - the core22 FIPS provider is loaded"
    elif [ -n "$lib" ]; then
      vbad "$name (pid $pid): $lib mapped, but NO FIPS provider - OpenSSL without fips.so"
    else
      vbad "$name (pid $pid): no libcrypto mapped - Go's own crypto, not the validated module (Q-CORE)"
    fi
  done
  # Container processes bring their own userland: reported, not judged - which OpenSSL an image
  # loads, and whether it is a validated one, is Q-CORE (ssp-inputs 1.3).
  for name in cilium-agent coredns metallb-speaker metallb-controller metrics-server; do
    # -f on the command line, not -x on the name: the kernel keeps only 15 characters of a
    # process name, so "metallb-controller" could never match -x (seen 2026-10-14)
    pid="$(pgrep -f "(^|/)$name( |$)" | head -1 || true)"
    [ -n "$pid" ] || continue
    maps="$(awk '$6 ~ /libcrypto|fips\.so/ {print $6}' "/proc/$pid/maps" 2>/dev/null | sort -u | tr '\n' ' ')"
    say "     info: container $name (pid $pid): ${maps:-no libcrypto mapped}"
  done
}

# The test workload: the CoreDNS image the cluster already runs (so nothing new is carried in),
# answering "whoami" on a dual-stack LoadBalancer Service, spread over the workers. It stays up
# as the target for the survivability tests; verify --cleanup removes it.
verify_manifest() {
  kc -n kube-system get deployment coredns -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = d["spec"]["template"]["spec"]["containers"][0]
ns = sys.argv[1]
ct = {"name": "whoami", "image": c["image"],
      "volumeMounts": [{"name": "corefile", "mountPath": "/etc/coredns"}],
      "ports": [{"containerPort": 1053, "protocol": "UDP"}, {"containerPort": 1053, "protocol": "TCP"}],
      "readinessProbe": {"tcpSocket": {"port": 1053}, "periodSeconds": 5}}
for k in ("command", "args"):
    if c.get(k): ct[k] = c[k]
items = [
 {"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": ns}},
 {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "whoami", "namespace": ns},
  "data": {"Corefile": ".:1053 {\n    whoami\n}\n"}},
 {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"name": "whoami", "namespace": ns},
  "spec": {"replicas": 4, "selector": {"matchLabels": {"app": "whoami"}},
   "template": {"metadata": {"labels": {"app": "whoami"}},
    "spec": {"topologySpreadConstraints": [{"maxSkew": 1, "topologyKey": "kubernetes.io/hostname",
               "whenUnsatisfiable": "ScheduleAnyway", "labelSelector": {"matchLabels": {"app": "whoami"}}}],
             "containers": [ct],
             "volumes": [{"name": "corefile", "configMap": {"name": "whoami"}}]}}}},
 {"apiVersion": "v1", "kind": "Service", "metadata": {"name": "whoami", "namespace": ns},
  "spec": {"type": "LoadBalancer", "ipFamilyPolicy": "RequireDualStack", "ipFamilies": ["IPv4", "IPv6"],
           "selector": {"app": "whoami"},
           "ports": [{"name": "dns-udp", "port": 53, "targetPort": 1053, "protocol": "UDP"},
                     {"name": "dns-tcp", "port": 53, "targetPort": 1053, "protocol": "TCP"}]}}]
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
' "$V_NS"
}

cmd_verify() {
  need_root
  whoami_k8s
  local mode="${1:-}"
  say "verify on $ME ($ME_ADDR, $ME_ADDR6) - $(date -u +%FT%TZ)"
  echo
  if [ "$mode" = --fips-only ]; then
    say "== FIPS in this node's processes"; verify_fips_node
    echo; [ "$V_FAIL" -eq 0 ] || die "$V_FAIL check(s) failed on $ME"; ok "$V_PASS checks passed on $ME"; return 0
  fi
  [ "$ME_ROLE" = cp ] || die "verify runs on a control plane (it needs the cluster's admin access); on a worker: verify --fips-only"
  if [ "$mode" = --cleanup ]; then
    kc delete namespace "$V_NS" --ignore-not-found --wait=true && ok "test workload removed ($V_NS)"; return 0
  fi
  [ -z "$mode" ] || die "unknown option: $mode (none, --fips-only or --cleanup)"

  # ---- 1. the cluster
  say "== 1. the cluster"
  local st cps want
  st="$(/snap/bin/k8s status 2>&1)" || true
  if printf '%s\n' "$st" | grep -q 'high availability: *yes'; then vok "high availability: yes"; else vbad "high availability is not yes"; fi
  cps="$(grep -cE '^K8S_CP_[0-9]+=' "$ADDRS")"
  if [ "$(printf '%s\n' "$st" | grep -o '(voter)' | wc -l)" -eq "$cps" ]; then vok "$cps etcd voters"; else vbad "voters: $(printf '%s\n' "$st" | grep -o '(voter)' | wc -l), want $cps"; fi
  want=""
  local k a
  for k in $(grep -oE '^K8S_(CP|WK)_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do
    a="${!k}"; want="$want $(printf '%s' "$k" | tr 'A-Z_' 'a-z-')=$a,$(node_v6 "$a")"
  done
  local nodes_out line
  nodes_out="$(kc get nodes -o json | WANT="$want" python3 -c '
import json, os, sys
want = dict(x.split("=") for x in os.environ["WANT"].split())
nodes = {n["metadata"]["name"]: n for n in json.load(sys.stdin)["items"]}
for name, addrs in sorted(want.items()):
    n = nodes.get(name)
    if not n: print("BAD %s is not in the cluster" % name); continue
    ready = any(c["type"] == "Ready" and c["status"] == "True" for c in n["status"]["conditions"])
    ips = sorted(a["address"] for a in n["status"]["addresses"] if a["type"] == "InternalIP")
    taint = any(t["key"] == "node-role.kubernetes.io/control-plane" for t in n["spec"].get("taints") or [])
    cp = name.startswith("k8s-cp-")
    ok = ready and ips == sorted(addrs.split(",")) and taint == cp
    print("%s %s: %s, InternalIP %s, %s" % ("OK" if ok else "BAD", name, "Ready" if ready else "NOT READY",
          " + ".join(ips), ("tainted" if taint else "untainted") + ("" if taint == cp else " - WRONG for its role")))
')"
  # counted in THIS shell - a pipe into 'while' would run in a subshell and lose the tally
  while IFS= read -r line; do case "$line" in OK*) vok "${line#OK }" ;; *) vbad "${line#BAD }" ;; esac; done <<< "$nodes_out"
  local stuck; stuck="$(kc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o name 2>&1)"
  if [ -z "$stuck" ]; then vok "every pod Running"; else vbad "pods not Running: $(printf '%s' "$stuck" | tr '\n' ' ')"; fi

  # ---- 2. FIPS in this node's processes
  echo; say "== 2. FIPS in this node's processes (repeat on any node: verify --fips-only)"
  verify_fips_node

  # ---- 3. DNS - CoreDNS answers, and its forward to the enclave DNS (pod traffic) gets through
  echo; say "== 3. DNS"
  local dnsip r
  dnsip="$(printf '%s\n' "$st" | sed -n 's/^dns: *enabled at //p' | awk '{print $1}')"
  if [ -z "$dnsip" ]; then vbad "no DNS address in k8s status"; else
    r="$(dig +short +time=3 +tries=2 @"$dnsip" kubernetes.default.svc.cluster.local A 2>&1 | head -1)"
    if [ "$r" = "${K8S_SERVICE_CIDR_V4%.*}.1" ]; then vok "CoreDNS $dnsip: kubernetes.default -> $r"; else vbad "CoreDNS $dnsip: kubernetes.default -> '${r:-no answer}'"; fi
    r="$(dig +short +time=3 +tries=2 @"$dnsip" "svc-mgmt-01.$ENCLAVE_DOMAIN" A 2>&1 | head -1)"
    if [ "$r" = "${SVC_MGMT_01:-}" ]; then vok "CoreDNS forwards enclave names: svc-mgmt-01.$ENCLAVE_DOMAIN -> $r"
    else vbad "CoreDNS did not resolve svc-mgmt-01.$ENCLAVE_DOMAIN: '${r:-no answer}' (want ${SVC_MGMT_01:-?}) - CoreDNS -> enclave DNS is routed pod traffic"; fi
  fi

  # ---- 4. a dual-stack LoadBalancer Service
  echo; say "== 4. dual-stack LoadBalancer (test workload: namespace $V_NS)"
  verify_manifest | kc apply -f - >/dev/null || die "could not apply the test workload"
  if kc -n "$V_NS" rollout status deployment/whoami --timeout=180s >/dev/null 2>"$WORK/rollout.err"; then
    vok "whoami: $(kc -n "$V_NS" get pods -l app=whoami -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{end}')"
  else vbad "whoami did not roll out: $(tail -1 "$WORK/rollout.err")"; fi
  local ips="" v4="" v6=""
  for _ in $(seq 1 30); do
    ips="$(kc -n "$V_NS" get svc whoami -o jsonpath='{.status.loadBalancer.ingress[*].ip}')"
    [ "$(printf '%s' "$ips" | wc -w)" -ge 2 ] && break; sleep 2
  done
  for a in $ips; do case "$a" in *:*) v6="$a" ;; *) v4="$a" ;; esac; done
  if [ -n "$v4" ]; then vok "IPv4 LoadBalancer address $v4"; else vbad "no IPv4 LoadBalancer address (got: ${ips:-none})"; fi
  if [ -n "$v6" ]; then vok "IPv6 LoadBalancer address $v6"; else vbad "no IPv6 LoadBalancer address (got: ${ips:-none})"; fi
  if [ -n "$v4" ]; then
    r="$(dig +noall +additional +time=3 +tries=2 @"$v4" whoami.verify 2>&1 | head -2 | tr -s ' \t\n' ' ')"
    if [ -n "$r" ]; then vok "answers on $v4: $r"; else vbad "no answer on $v4"; fi
  fi
  if [ -n "$v6" ]; then
    r="$(dig -6 +noall +additional +time=3 +tries=2 @"$v6" whoami.verify 2>&1 | head -2 | tr -s ' \t\n' ' ')"
    if [ -n "$r" ]; then vok "answers on $v6 (IPv6): $r"; else vbad "no answer on $v6"; fi
  fi

  # ---- 5. the audit policy (K-A): a Secret's VALUE never reaches the log; the event does
  echo; say "== 5. the API audit policy (K-A)"
  local log=/var/log/kubernetes/audit.log marker b64 since
  marker="enclave-verify-$(date +%s)-$RANDOM"; b64="$(printf '%s' "$marker" | base64 -w0)"
  since="$(date -u +%FT%T)"
  kc -n "$V_NS" create secret generic enclave-verify-audit --from-literal=probe="$marker" >/dev/null 2>&1 \
    || { kc -n "$V_NS" delete secret enclave-verify-audit >/dev/null 2>&1; kc -n "$V_NS" create secret generic enclave-verify-audit --from-literal=probe="$marker" >/dev/null; }
  sleep 3
  if [ ! -r "$log" ]; then vbad "no audit log at $log"; else
    if grep -qF -e "$marker" -e "$b64" "$log"; then vbad "the Secret's value IS in $log - K-A is not in force"
    else vok "the Secret's value (plain and base64) is NOT in $log"; fi
    r="$(SINCE="$since" NS="$V_NS" python3 -c '
import json, os, sys
seen = []
for line in open(sys.argv[1], errors="replace"):
    try: e = json.loads(line)
    except ValueError: continue
    o = e.get("objectRef") or {}
    if o.get("resource") == "secrets" and o.get("name") == "enclave-verify-audit" and e.get("verb") == "create" \
       and e.get("requestReceivedTimestamp", "") >= os.environ["SINCE"]:
        seen.append("%s body=%s" % (e.get("level"), "yes" if "requestObject" in e else "no"))
print(seen[-1] if seen else "")' "$log")"
    case "$r" in
      "Metadata body=no") vok "the create was logged at Metadata, no request body" ;;
      "") vbad "no create event for the probe Secret in this node's log - another API server may have served it; run verify on that control plane" ;;
      *) vbad "the create was logged as: $r - want Metadata with no body" ;;
    esac
  fi
  kc -n "$V_NS" delete secret enclave-verify-audit >/dev/null 2>&1 || true

  echo
  [ "$V_FAIL" -eq 0 ] || die "$V_FAIL check(s) failed - read the [x] lines above"
  ok "all $V_PASS checks passed - the test workload stays up in $V_NS (verify --cleanup removes it)"
}

case "${1:-}" in
  verify)        shift; cmd_verify "$@" ;;
  node-prep)     shift; cmd_node_prep "$@" ;;
  render)        shift; cmd_render "$@" ;;
  bootstrap)     shift; cmd_bootstrap "$@" ;;
  join-token)    shift; cmd_join_token "$@" ;;
  join-tokens)   shift; cmd_join_tokens "$@" ;;
  join)          shift; cmd_join "$@" ;;
  images-export) shift; cmd_images_export "$@" ;;
  images-load)   shift; cmd_images_load "$@" ;;
  images-check)  shift; cmd_images_check "$@" ;;
  *) sed -n '2,39p' "$0"; exit 2 ;;
esac
