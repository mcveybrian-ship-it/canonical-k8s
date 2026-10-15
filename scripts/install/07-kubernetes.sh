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
#     sudo ./07-kubernetes.sh vip                each control plane: keepalived holds the API VIP
#                                                (K8S_API_VIP) on whichever answers, VRRP unicast
#     sudo ./07-kubernetes.sh etcd-drill         a control plane: snapshot the cluster's etcd, check
#                                                it, restore it into a SCRATCH directory (never the
#                                                live data), shred both - proves a restore would work
#     sudo ./07-kubernetes.sh etcd-backup --setup   EACH control plane: its key, and what to run on each
#                                                store to authorise it (write-only, one directory)
#     sudo ./07-kubernetes.sh etcd-backup [--force] the nightly job (G9): on the VIP holder a snapshot,
#                                                restore-tested, kept, pushed to the stores; the
#                                                Secrets scan; published for Prometheus
#     sudo ./07-kubernetes.sh etcd-backup --timer   EACH control plane: that job nightly at K8S_ETCD_BACKUP_AT
#     sudo ./07-kubernetes.sh encrypt check      a control plane: every Secret in etcd, by how it is stored -
#                                                under the current key, an older one, or PLAIN (STIG
#                                                V-274882, backlog 3.64). Read-only
#     sudo ./07-kubernetes.sh encrypt stage      EACH control plane in turn: the key held, not yet used
#     sudo ./07-kubernetes.sh encrypt apply      EACH control plane in turn, once ALL are staged: the key
#                                                writes; a canary proves every API server can read it
#     sudo ./07-kubernetes.sh encrypt rewrite    ONE control plane, once all apply: every Secret stored again
#     sudo ./07-kubernetes.sh encrypt retire     EACH control plane, once 'check' passes: older keys and the
#                                                plain-text reader removed (Kubernetes' last two steps)
#     sudo ./07-kubernetes.sh encrypt status     this node: the config, the argument, the running process
#          ./07-kubernetes.sh probe service|api|patroni [minutes]
#                                                the failover-test probes, one sample a second,
#                                                printing only changes: service and api ON
#                                                svc-mgmt-01, patroni ON svc-obs-01 (what ufw allows).
#                                                Each refuses to start until it has seen itself
#                                                report DOWN against a target known to be dead
#     sudo ./07-kubernetes.sh verify             on a control plane: the cluster, FIPS in the
#                                                running processes, DNS, a dual-stack LoadBalancer
#                                                Service, the K-A audit policy, Secrets encrypted
#                                                by this API server (V-274882). Leaves the test
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
# SECRETS AT REST (backlog 3.64, STIG V-274882; decided 2026-10-15: aesgcm). The keys derive from
# K8S_SECRETS_PASS in the site credentials; K8S_SECRETS_GEN is the generation that WRITES - raise it to
# rotate (07-kubernetes.md 3.12), and commit the change: a control plane rebuilt later reads it here.
K8S_SECRETS_PROVIDER="${K8S_SECRETS_PROVIDER:-aesgcm}"
K8S_SECRETS_GEN="${K8S_SECRETS_GEN:-1}"
K8S_SECRETS_MIN_LEN="${K8S_SECRETS_MIN_LEN:-32}"
K8S_ENC_CONFIG="${K8S_ENC_CONFIG:-$K8S_CONF_DIR/enclave-encryption.yaml}"
K8S_APISERVER_ARGS="${K8S_APISERVER_ARGS:-/var/snap/k8s/common/args/kube-apiserver}"
K8S_ENC_WAIT="${K8S_ENC_WAIT:-180}"
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
    # 5. Secrets at rest (3.64). A NEW control plane gets the final config here, before its API server
    #    first starts. On a running member it changes only through 'encrypt stage' then 'apply' -
    #    writing the final config onto one live API server first is the failure those two steps avoid.
    if /snap/bin/k8s status >/dev/null 2>&1; then
      if [ -n "$(enc_state)" ]; then ok "Secrets encryption: $(enc_state | cut -d' ' -f1-3) - changed only by 'encrypt'"
      else warn "no Secrets encryption config on this running control plane - 'encrypt stage' then 'encrypt apply' (07-kubernetes.md 3.12)"; fi
    else
      enc_write_config derive "gen$K8S_SECRETS_GEN"
    fi
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
  awk -v audit="$K8S_AUDIT_POLICY" -v psa="$K8S_PSA_FILE" -v nodeip="$ME_ADDR,$ME_ADDR6" -v enc="$K8S_ENC_CONFIG" '
    /^extra-node-[a-z-]+-args:/ { blk = $1; print
                                  if (blk == "extra-node-kubelet-args:") print "  --node-ip: \"" nodeip "\"   # both families (B-07 A2)"
                                  if (blk == "extra-node-kube-apiserver-args:") print "  --encryption-provider-config: " enc "   # 3.64: Secrets encrypted at rest (V-274882)"
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
  [ -r "$K8S_ENC_CONFIG" ] || die "no Secrets encryption config at $K8S_ENC_CONFIG - run node-prep first (3.64)"
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
    [ -r "$K8S_ENC_CONFIG" ] || die "no Secrets encryption config at $K8S_ENC_CONFIG - run node-prep first (3.64)"
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

# ===================================================================== failover probes (C)
# Used for the survivability tests (07-kubernetes.md 4.1, 4.2). THE LESSON OF 2026-10-15 IS BUILT IN:
# the first service probe counted dig's timeout message as an answer and reported "never missed"
# through four failure tests. So each probe first samples a target that CANNOT answer and refuses to
# run unless that sample reads DOWN - a probe nobody has seen fail is not a probe.
P_SERVICE_ADDR="${P_SERVICE_ADDR:-$K8S_LB_POOL_START}"   # the test Service's address (verify's whoami)
P_SERVICE_PORT="${P_SERVICE_PORT:-53}"

# node_of MAC - the k8s node with that MAC, from this machine's neighbour table (filled by pinging
# each node once at start); the MAC itself if none matches.
P_NODES=""
p_learn_nodes() {
  local k a n
  for k in $(grep -oE '^K8S_(CP|WK)_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do
    a="${!k}"; n="$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')"
    ping -c1 -W1 "$a" >/dev/null 2>&1 || true
    P_NODES="$P_NODES $(ip neigh show "$a" | awk '{print $5}')=$n"
  done
}
node_of() { local m="${1:-}" x; for x in $P_NODES; do [ "${x%%=*}" = "$m" ] && { printf '%s' "${x#*=}"; return; }; done; printf '%s' "${m:-no-arp}"; }

# one sample of each kind -> a state word
p_service() {  # ADDR PORT
  if dig -p "$2" +noall +additional +time=1 +tries=1 @"$1" whoami.verify 2>/dev/null | grep -qE '[[:space:]]IN[[:space:]]+(A|AAAA)[[:space:]]'
  then printf 'SERVICE-UP@%s' "$(node_of "$(ip neigh show "$1" | awk '{print $5}')")"
  else printf 'SERVICE-DOWN'; fi
}
p_api() {  # PORT
  local c; c="$(curl -sk --max-time 1 -o /dev/null -w '%{http_code}' "https://$K8S_API_VIP:$1/livez" 2>/dev/null || true)"
  case "$c" in 401|200) printf 'API-UP@%s' "$(node_of "$(ip neigh show "$K8S_API_VIP" | awk '{print $5}')")" ;;
               *) printf 'API-DOWN(%s)' "${c:-000}" ;; esac
}
p_patroni() {  # PORT
  local k j=""
  for k in $(grep -oE '^PG_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do
    j="$(curl -sk --max-time 1 "https://${!k}:$1/cluster" 2>/dev/null || true)"; [ -n "$j" ] && break
  done
  printf '%s' "$j" | python3 -c '
import json, sys
try:
    m = json.load(sys.stdin)["members"]; r = {x["role"]: x["name"] for x in m}
    up = len([x for x in m if x["state"] in ("running", "streaming")])
    print("PG:leader=%s sync=%s members=%d" % (r.get("leader", "NONE"), r.get("sync_standby", "NONE"), up), end="")
except Exception:
    print("PG:NO-ANSWER", end="")'
}

cmd_probe() {
  local kind="${1:-}" mins="${2:-60}" st last="" since=0 now end
  case "$mins" in ''|*[!0-9]*) die "minutes must be a number" ;; esac
  case "$kind" in
    service) command -v dig >/dev/null || die "no dig here" ;;
    api|patroni) command -v curl >/dev/null || die "no curl here" ;;
    *) die "usage: probe service|api|patroni [minutes] - service and api on svc-mgmt-01, patroni on svc-obs-01" ;;
  esac
  # THE SELF-TEST: the same check against a target that cannot answer must read DOWN.
  case "$kind" in
    service) st="$(p_service "$P_SERVICE_ADDR" 9)" ;;   # nothing serves DNS on port 9
    api)     st="$(p_api 1)" ;;
    patroni) st="$(p_patroni 1)" ;;
  esac
  case "$st" in *DOWN*|*NO-ANSWER*) ok "self-test: against a dead target the probe reads '$st' - it can see a failure" ;;
    *) die "self-test FAILED: against a target that cannot answer the probe read '$st' - it would report a failure as success; not starting" ;; esac
  [ "$kind" = patroni ] || p_learn_nodes
  say "probing $kind for $mins min, one sample a second - only changes are printed (UTC)"
  end=$(( $(date +%s) + mins * 60 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    case "$kind" in
      service) st="$(p_service "$P_SERVICE_ADDR" "$P_SERVICE_PORT")" ;;
      api)     st="$(p_api 6443)" ;;
      patroni) st="$(p_patroni 8008)" ;;
    esac
    now="$(date +%s)"
    if [ "$st" != "$last" ]; then
      if [ -n "$last" ]; then printf '  %s  %-40s (previous state lasted %ss)\n' "$(date -u -d "@$now" +%T)" "$st" "$((now - since))"
      else printf '  %s  %-40s (start)\n' "$(date -u -d "@$now" +%T)" "$st"; fi
      last="$st"; since="$now"
    fi
    sleep 1
  done
}

# ===================================================================== the etcd drill (C4)
# etcdctl and etcdutl are NOT in the k8s snap (Canonical's etcd reference) and Ubuntu's etcd-client
# is 3.4 with no etcdutl, so the restore tools are etcd's own release at the cluster's version,
# staged on the mirror's /bin like regctl. They are ordinary Go builds, NOT FIPS: tools for a drill
# or a recovery, never a running service (the same class as the database's etcd, POA&M ENG-68).
# They live only in this run's private WORK directory - nothing is installed on the node.
K8S_ETCD_TOOLS_VER="${K8S_ETCD_TOOLS_VER:-3.6.13}"
K8S_BIN_URL="${K8S_BIN_URL:-https://svc-repo-01.${ENCLAVE_DOMAIN}/bin}"
K8S_ETCD_CA="${K8S_ETCD_CA:-/etc/kubernetes/pki/etcd/ca.crt}"
K8S_ETCD_CERT="${K8S_ETCD_CERT:-/etc/kubernetes/pki/apiserver-etcd-client.crt}"   # Canonical's restore-quorum how-to
K8S_ETCD_KEY="${K8S_ETCD_KEY:-/etc/kubernetes/pki/apiserver-etcd-client.key}"

# etcd_tools - etcdctl and etcdutl at the cluster's own etcd version, from the mirror, checksum-verified,
# into this run's WORK directory only. Then ectl talks to this node's etcd with the API server's client
# certificate.
etcd_tools() {
  # THE TOOLS MUST MATCH THE CLUSTER - read the running snap's own bill of materials.
  local have; have="$(python3 -c 'import json; print(json.load(open("/snap/k8s/current/bom.json"))["components"]["etcd"]["version"])' 2>&1)" \
    || die "could not read the etcd version from /snap/k8s/current/bom.json: $have"
  [ "${have#v}" = "$K8S_ETCD_TOOLS_VER" ] || die "the cluster runs etcd $have, the drill tools are $K8S_ETCD_TOOLS_VER - stage matching tools (K8S_ETCD_TOOLS_VER)"
  ok "cluster etcd $have - tools $K8S_ETCD_TOOLS_VER match"
  local f
  for f in "$K8S_ETCD_CA" "$K8S_ETCD_CERT" "$K8S_ETCD_KEY"; do [ -r "$f" ] || die "missing $f"; done

  # the tools, from the mirror, checked against its SHA256SUMS. With a CACHE directory (the nightly
  # backup, G9) they are kept root-only between runs and re-checked against the kept SHA256SUMS each
  # time - so a backup does not need svc-repo-01 up; without one they live in this run's WORK only.
  ETCD_BIN="${1:-$WORK/bin}"
  install -d -m 0700 -o root -g root "$ETCD_BIN"
  if [ -n "${1:-}" ] && etcd_tools_ok "$ETCD_BIN"; then
    ok "etcdctl and etcdutl $K8S_ETCD_TOOLS_VER from $ETCD_BIN - checksums match"; return 0
  fi
  curl -fsS --cacert "$CA_ROOT" -o "$ETCD_BIN/SHA256SUMS" "$K8S_BIN_URL/SHA256SUMS" || die "could not fetch $K8S_BIN_URL/SHA256SUMS"
  local t want got
  for t in etcdctl etcdutl; do
    curl -fsS --cacert "$CA_ROOT" -o "$ETCD_BIN/$t" "$K8S_BIN_URL/$t-v$K8S_ETCD_TOOLS_VER" || die "could not fetch $K8S_BIN_URL/$t-v$K8S_ETCD_TOOLS_VER - staged on the mirror?"
    want="$(awk -v n="$t-v$K8S_ETCD_TOOLS_VER" '$2 == n {print $1}' "$ETCD_BIN/SHA256SUMS")"
    got="$(sha256sum "$ETCD_BIN/$t" | cut -c1-64)"
    if [ -z "$want" ] || [ "$want" != "$got" ]; then die "$t-v$K8S_ETCD_TOOLS_VER does not match the mirror's SHA256SUMS (want ${want:-none}, got $got)"; fi
    chmod 0700 "$ETCD_BIN/$t"
  done
  ok "etcdctl and etcdutl $K8S_ETCD_TOOLS_VER fetched and checksum-verified$( [ -n "${1:-}" ] && echo ", kept in $ETCD_BIN" || echo " (this run only)")"
}
etcd_tools_ok() {   # <dir> - both tools present and matching the SHA256SUMS kept beside them
  local t want got
  [ -s "$1/SHA256SUMS" ] || return 1
  for t in etcdctl etcdutl; do
    [ -x "$1/$t" ] || return 1
    want="$(awk -v n="$t-v$K8S_ETCD_TOOLS_VER" '$2 == n {print $1}' "$1/SHA256SUMS")"
    got="$(sha256sum "$1/$t" | cut -c1-64)"
    [ -n "$want" ] && [ "$want" = "$got" ] || return 1
  done
}
ETCD_BIN=""
ectl() { "$ETCD_BIN/etcdctl" --endpoints=https://127.0.0.1:2379 --cacert "$K8S_ETCD_CA" --cert "$K8S_ETCD_CERT" --key "$K8S_ETCD_KEY" "$@"; }

cmd_etcd_drill() {
  need_root
  whoami_k8s
  [ "$ME_ROLE" = cp ] || die "etcd runs on the control planes - this is $ME"
  etcd_tools

  # 1. the snapshot
  local snap="$WORK/snapshot.db" out
  out="$("$ETCD_BIN/etcdctl" --endpoints=https://127.0.0.1:2379 --cacert "$K8S_ETCD_CA" --cert "$K8S_ETCD_CERT" --key "$K8S_ETCD_KEY" \
         snapshot save "$snap" 2>&1)" || die "snapshot failed: $(printf '%s' "$out" | tail -3)"
  chmod 0600 "$snap"
  ok "snapshot taken: $(du -h "$snap" | cut -f1)"

  # 2. what is in it
  out="$("$ETCD_BIN/etcdutl" snapshot status "$snap" -w json 2>&1)" || die "snapshot status failed: $out"
  printf '%s' "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read().strip().splitlines()[-1]); print("  [ok] snapshot status: hash %s, revision %s, %s keys, %.1f MB" % (d.get("hash"), d.get("revision"), d.get("totalKey"), d.get("totalSize", 0) / 1e6))' \
    || die "could not read the snapshot status: $out"

  # 3. restore it - into SCRATCH, with a throwaway member name; the live data dir is never named
  out="$("$ETCD_BIN/etcdutl" snapshot restore "$snap" --data-dir "$WORK/restore" --name drill \
         --initial-cluster drill=http://127.0.0.1:12380 --initial-advertise-peer-urls http://127.0.0.1:12380 2>&1)" \
    || die "RESTORE FAILED - the snapshot is not usable: $(printf '%s' "$out" | tail -3)"
  [ -s "$WORK/restore/member/snap/db" ] || die "the restore reported success but wrote no member/snap/db"
  ok "restored into a scratch directory: member/snap/db $(du -h "$WORK/restore/member/snap/db" | cut -f1) - the snapshot is usable (its hash was checked by the restore)"

  # 4. both copies hold every Secret in the cluster - shred, do not just delete
  shred -u "$snap" "$WORK/restore/member/snap/db"
  ok "the snapshot and the restored copy shredded"
  echo
  ok "etcd drill passed on $ME - a restore follows Canonical's quorum-loss procedure (docs/07-kubernetes.md)"
}

# ===================================================================== Secrets at rest (3.64)
# Kubernetes STIG V-274882 (CAT I): "If the setting encryption-provider-config is not configured, this
# is a finding." It was not (k8s-cp-01, 2026-10-15): every Secret plain in etcd, in every etcd snapshot
# and in every disk copy of a control plane. Canonical's STIG configuration does not cover the rule.
#
# THE PROVIDER (decided 2026-10-15, Brian): aesgcm - AES through the API server's OpenSSL (the binary is
# Go's opensslcrypto build, read from the snap 2026-10-15; the FIPS provider is loaded, verify 2).
# Kubernetes wants its key replaced before 200,000 writes; K8S_SECRETS_GEN is that rotation. aescbc is
# the alternative (no rotation; Kubernetes calls it weak) - K8S_SECRETS_PROVIDER, fixed for the life of
# a cluster: switching provider on a live one is not built.
#
# THE KEYS DERIVE FROM ONE SEALED PASSPHRASE (K8S_SECRETS_PASS - the same custody as pgBackRest's).
# Every control plane, and any rebuild, computes the same keys: no key is ever copied between
# machines, and a lost control plane loses nothing. The passphrase is NOT kept on the host - only the
# derived keys are - so 'retire' removing an old key from the file does protect something: the etcd
# snapshots taken under it, against a later compromise of a control plane. Generations differ only
# by their salt. Rotation serves AES-GCM's per-key write limit, NOT a compromise: a leaked passphrase
# needs a new one, which is not built (07-kubernetes.md 3.12).
#
# TWO STEPS ON A RUNNING CLUSTER - Kubernetes' procedure for more than one API server: a Secret written
# by an API server with the new key cannot be read by one without it. So every API server first learns
# the key without using it (stage), then each starts writing with it (apply), then every Secret is
# stored again (rewrite), and once etcd proves it, the old key and the plain-text reader go (retire).
# A NEW control plane gets its config from node-prep, before its API server first starts, and the
# argument through its bootstrap/join config - like the audit policy.
#
# THE ARGUMENT on a running node goes into Canonical's args file, which the snap's service wrapper reads
# as shell words (k8s/lib.sh, rev 5526). The edit keeps the previous file as <file>.pre-3.64.
ENC_CHANGED=0

enc_state() { [ -f "$K8S_ENC_CONFIG" ] || return 0; sed -n 's/^# enclave-state: //p' "$K8S_ENC_CONFIG" | head -1; }
enc_field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

enc_check_params() {
  case "$K8S_SECRETS_PROVIDER" in aesgcm|aescbc) ;;
    *) die "K8S_SECRETS_PROVIDER='$K8S_SECRETS_PROVIDER' - aesgcm or aescbc (secretbox is not FIPS-approved; kms needs a key service the enclave does not have)" ;; esac
  case "$K8S_SECRETS_GEN" in ''|0|*[!0-9]*) die "K8S_SECRETS_GEN='$K8S_SECRETS_GEN' - a generation number, from 1" ;; esac
}

# enc_pass -> the passphrase on stdout: the environment, then the site credentials file, then the
# terminal - asked twice, never echoed. The CALLER runs cred_require_safe first (credentials.sh says why).
enc_pass() {
  local p="${K8S_SECRETS_PASS:-}" b=""
  [ -n "$p" ] || p="$(cred_get K8S_SECRETS_PASS)"
  if [ -z "$p" ]; then
    { : </dev/tty; } 2>/dev/null || { echo "  [x] no K8S_SECRETS_PASS in the environment or $ENCLAVE_CREDENTIALS, and no terminal to ask on" >&2; return 1; }
    read -rsp "  Secrets-encryption passphrase (K8S_SECRETS_PASS): " p </dev/tty; echo >&2
    read -rsp "  again: " b </dev/tty; echo >&2
    [ "$p" = "$b" ] || { echo "  [x] the two entries differ" >&2; return 1; }
    b=""
  fi
  [ "${#p}" -ge "$K8S_SECRETS_MIN_LEN" ] || { echo "  [x] the passphrase is shorter than $K8S_SECRETS_MIN_LEN characters" >&2; return 1; }
  case "$p" in *"'"*|*$'\n'*) echo "  [x] the passphrase contains a ' or a newline" >&2; return 1 ;; esac
  printf '%s' "$p"
}

# The config, always rebuilt WHOLE - never edited in place. derive: genN from the passphrase on stdin,
# and every key this node already holds derived again and compared (a mistyped passphrase is refused,
# not stored). reorder: the keys already in the file, a different one first. retire: only the key
# that writes - no older key, no identity. Output has no timestamp, so an unchanged config compares
# equal and causes no restart.
ENC_PY="$(cat <<'PYEOF'
import base64, hashlib, os, re, sys
# PART OF EVERY KEY'S DEFINITION: changing either one changes every key, and the Secrets stored under
# the old keys can no longer be read. Deliberately not parameters.
ITER = 600000
LABEL = "k8s-secrets-at-rest/gen%d"
mode, out, provider, write, gens, existing = sys.argv[1:7]

def fp(b): return hashlib.sha256(b).hexdigest()[:8]
def fail(msg):
    sys.stderr.write("  [x] %s\n" % msg); sys.exit(3)

have, had_identity, had_write = {}, True, None
if os.path.exists(existing):
    t = open(existing).read()
    had_identity = re.search(r"^ +- identity: \{\}$", t, re.M) is not None
    mw = re.search(r"^# enclave-state: .* write=(\S+) ", t, re.M)
    had_write = mw.group(1) if mw else None
    m = re.search(r"^# enclave-state: provider=(\w+) ", t, re.M)
    have = {int(n): base64.b64decode(s) for n, s in re.findall(r'- name: gen(\d+)\n\s+secret: "([A-Za-z0-9+/=]+)"', t)}
    if not m or not have: fail("%s exists but was not written by this script - not touching it" % existing)
    if m.group(1) != provider:
        fail("%s uses %s, K8S_SECRETS_PROVIDER is %s - changing provider on a live cluster is not built" % (existing, m.group(1), provider))
keys = dict(have)
if mode == "derive":
    pw = sys.stdin.buffer.read()
    if not pw: fail("no passphrase")
    print("passphrase fingerprint %s (sha256, first 8) - must match the envelope, and every control plane" % fp(pw))
    for g in sorted(set(int(x) for x in gens.split()) | set(have)):
        k = hashlib.pbkdf2_hmac("sha256", pw, (LABEL % g).encode(), ITER, 32)
        if g in have and have[g] != k:
            fail("this passphrase does not reproduce gen%d, which this node already holds - mistyped, or a different passphrase" % g)
        keys[g] = k
    pw = None
elif mode not in ("reorder", "retire"):
    fail("unknown mode %s" % mode)
w = None if write == "identity" else int(write[3:])
if w is not None and w not in keys: fail("gen%d is not in %s - stage it first" % (w, existing))
if mode == "retire":
    if w is None or had_write != "gen%d" % w:
        fail("this node writes with %s, not %s - retire only the key that already writes" % (had_write, write))
    keys, identity = {w: keys[w]}, False
else:
    identity = w is None or had_identity
order = sorted(keys, reverse=True)
if w is not None:
    order.remove(w); order.insert(0, w)
aes = ["      - %s:" % provider, "          keys:"]
for g in order:
    aes += ["            - name: gen%d" % g, '              secret: "%s"' % base64.b64encode(keys[g]).decode()]
ident = ["      - identity: {}"]
state = "provider=%s write=%s keys=%s plain=%s fingerprints=%s" % (
    provider, "identity" if w is None else "gen%d" % w, ",".join("gen%d" % g for g in order),
    "readable" if identity else "refused", ",".join("gen%d:%s" % (g, fp(keys[g])) for g in order))
text = "\n".join([
    "# enclave-encryption.yaml - written by 07-kubernetes.sh (backlog 3.64, Kubernetes STIG V-274882).",
    "# SECRET-BEARING: these keys decrypt every Secret in etcd and in every etcd snapshot. Never print,",
    "# copy or commit this file. Each key derives from K8S_SECRETS_PASS (site credentials, sealed envelope):",
    "#   gen<N> = PBKDF2-HMAC-SHA256(passphrase, \"k8s-secrets-at-rest/gen<N>\", %d iterations, 32 bytes)" % ITER,
    "# The FIRST provider below writes; the others only read. identity, while present, reads plain Secrets.",
    "# enclave-state: " + state,
    "apiVersion: apiserver.config.k8s.io/v1",
    "kind: EncryptionConfiguration",
    "resources:",
    "  - resources:",
    "      - secrets",
    "    providers:"] + ((ident + aes) if w is None else (aes + (ident if identity else [])))) + "\n"
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(text)
print("state: " + state)
PYEOF
)"

# enc_write_config derive|reorder|retire WRITE  (WRITE: identity | genN) - ENC_CHANGED=1 if it changed
enc_write_config() {
  local mode="$1" write="$2" new="$K8S_ENC_CONFIG.new" pass="" out
  enc_check_params
  [ -d "$K8S_CONF_DIR" ] || install -d -m 0755 "$K8S_CONF_DIR"
  rm -f "$new"
  if [ "$mode" = derive ]; then
    cred_require_safe
    pass="$(enc_pass)" || die "no Secrets-encryption passphrase - nothing changed"
    out="$(printf '%s' "$pass" | python3 -c "$ENC_PY" derive "$new" "$K8S_SECRETS_PROVIDER" "$write" "$K8S_SECRETS_GEN" "$K8S_ENC_CONFIG")" \
      || { pass=""; rm -f "$new"; die "the encryption config was not written - nothing changed"; }
    pass=""
  else
    out="$(python3 -c "$ENC_PY" "$mode" "$new" "$K8S_SECRETS_PROVIDER" "$write" "" "$K8S_ENC_CONFIG" </dev/null)" \
      || { rm -f "$new"; die "the encryption config was not written - nothing changed"; }
  fi
  printf '%s\n' "$out" | sed 's/^/  /'
  if [ -f "$K8S_ENC_CONFIG" ] && cmp -s "$new" "$K8S_ENC_CONFIG"; then rm -f "$new"; ok "$K8S_ENC_CONFIG unchanged"
  else mv -f "$new" "$K8S_ENC_CONFIG"; ok "$K8S_ENC_CONFIG written (root 0600 - never print it)"; ENC_CHANGED=1; fi
}

# The argument, in Canonical's args file - added once, never duplicated.
enc_args_ensure() {
  local a="$K8S_APISERVER_ARGS" line="--encryption-provider-config=$K8S_ENC_CONFIG"
  [ -f "$a" ] || die "no $a - the API server is not set up on $ME"
  if grep -qxF -- "$line" "$a"; then ok "$a already names the config"; return 0; fi
  [ -e "$a.pre-3.64" ] || cp -p "$a" "$a.pre-3.64"
  { grep -v -- '^--encryption-provider-config=' "$a" || true; printf '%s\n' "$line"; } > "$a.new"
  chmod --reference="$a" "$a.new"; chown --reference="$a" "$a.new"
  mv -f "$a.new" "$a"
  ok "$a: $line (the previous file kept as $a.pre-3.64)"
  ENC_CHANGED=1
}

enc_apiserver_pid() { pgrep -f '^/snap/k8s/[^ ]*/bin/kube-apiserver( |$)' | head -1 || true; }

# enc_running -> "yes" only when the RUNNING API server has the argument AND started after the config
# was last written - a config on disk the process has not read is not in force.
enc_running() {
  local pid age
  pid="$(enc_apiserver_pid)"
  [ -n "$pid" ] || { printf 'not running'; return 0; }
  tr '\0' '\n' < "/proc/$pid/cmdline" | grep -qxF -- "--encryption-provider-config=$K8S_ENC_CONFIG" \
    || { printf 'running WITHOUT the argument'; return 0; }
  [ -f "$K8S_ENC_CONFIG" ] || { printf 'running with the argument but NO config file'; return 0; }
  age="$(ps -o etimes= -p "$pid" | tr -d ' ')"
  if [ $(( $(date +%s) - age + 1 )) -lt "$(stat -c %Y "$K8S_ENC_CONFIG")" ]; then printf 'running an OLDER config - not restarted since'; return 0; fi
  printf 'yes'
}

# THIS node's API server, by its own address - not the VIP, not another control plane.
enc_ready() { kc --server="https://$ME_ADDR:6443" get --raw=/readyz >/dev/null 2>&1; }

# ONE CONTROL PLANE AT A TIME (found 2026-10-15): apply was run on cp-02 and cp-03 at once, both API
# servers restarted together, and each one's canary read through the other hit a server mid-restart -
# reported as a key failure that was not one. So nothing changes here while another control plane's
# API server is not ready: that is what a concurrent run on another node looks like from this one.
enc_peers_ready() {
  local k a n
  for k in $(grep -oE '^K8S_CP_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do
    a="${!k}"; n="$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')"
    [ "$a" != "$ME_ADDR" ] || continue
    kc --server="https://$a:6443" get --raw=/readyz >/dev/null 2>&1 \
      || die "the API server on $n is not ready - it may be restarting for this same step. One control plane at a time: wait for it, then run this again. Nothing changed here"
  done
}

enc_restart() {
  local i
  say "restarting the API server on $ME - if it holds the VIP, the VIP moves (3-4 s, measured in C1)"
  snap restart k8s.kube-apiserver >/dev/null || die "snap restart k8s.kube-apiserver failed"
  for i in $(seq 1 "$K8S_ENC_WAIT"); do
    sleep 1
    if enc_ready; then ok "the API server on $ME is ready again after ~${i}s"; break; fi
    [ "$i" -lt "$K8S_ENC_WAIT" ] || die "the API server on $ME is not ready after ${K8S_ENC_WAIT}s. Its log:
         sudo journalctl -u snap.k8s.kube-apiserver -n 40 --no-pager
       To back THIS NODE out - only while no Secret is stored under a key it would then lack (3.12):
         sudo cp -p $K8S_APISERVER_ARGS.pre-3.64 $K8S_APISERVER_ARGS && sudo snap restart k8s.kube-apiserver"
  done
  [ "$(enc_running)" = yes ] || die "the API server restarted, but: $(enc_running)"
  ok "the running API server has the argument and started after the config was written"
}

# A Secret written through THIS API server, read back through EVERY control plane's - proves each one
# holds the same key. The value is a throwaway, never a real secret.
enc_canary() {
  local name="enclave-enc-canary-$ME" val k a n got bad=0
  val="canary-$(date +%s)-$RANDOM"
  kc --server="https://$ME_ADDR:6443" -n kube-system delete secret "$name" --ignore-not-found >/dev/null 2>&1 || true
  kc --server="https://$ME_ADDR:6443" -n kube-system create secret generic "$name" --from-literal=v="$val" >/dev/null \
    || die "could not write the canary Secret through $ME"
  for k in $(grep -oE '^K8S_CP_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do
    a="${!k}"; n="$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')"
    # A server that does not ANSWER is not a key failure: retried for up to 30 s. A decryption error
    # is the real thing and is reported at once.
    for _ in $(seq 1 30); do
      got="$(kc --server="https://$a:6443" -n kube-system get secret "$name" -o jsonpath='{.data.v}' 2>&1 || true)"
      [ "$(printf '%s' "$got" | base64 -d 2>/dev/null || true)" = "$val" ] && break
      printf '%s' "$got" | grep -qiE 'transform|decrypt|authentication failed|matching prefix' && break
      sleep 1
    done
    if [ "$(printf '%s' "$got" | base64 -d 2>/dev/null || true)" = "$val" ]; then ok "$n reads it"
    elif printf '%s' "$got" | grep -qiE 'transform|decrypt|authentication failed|matching prefix'; then
      warn "$n CANNOT DECRYPT it - a different key, or not staged: $(printf '%s' "$got" | tail -1 | cut -c1-200)"; bad=1
    else warn "$n did not answer for 30 s - not a key result either way: $(printf '%s' "$got" | tail -1 | cut -c1-160)"; bad=1; fi
  done
  kc --server="https://$ME_ADDR:6443" -n kube-system delete secret "$name" >/dev/null 2>&1 || true
  return "$bad"
}

enc_status() {
  local st cur run arg=no
  st="$(enc_state)"; cur="$(enc_field "$st" write)"
  if [ -n "$st" ]; then ok "config: $st"; else say "no config at $K8S_ENC_CONFIG"; fi
  if [ -f "$K8S_APISERVER_ARGS" ] && grep -qxF -- "--encryption-provider-config=$K8S_ENC_CONFIG" "$K8S_APISERVER_ARGS"; then arg=yes; fi
  say "argument in $K8S_APISERVER_ARGS: $arg"
  run="$(enc_running)"; say "running API server: $run"
  if [ "$run" = yes ] && [ -n "$cur" ] && [ "$cur" != identity ]; then
    ok "V-274882 on $ME: this API server writes Secrets with $cur - what etcd holds: 'encrypt check'"
    [ "$(enc_field "$st" plain)" = refused ] || say "plain Secrets are still readable here (identity last) - 'encrypt retire' once 'check' passes"
  elif [ "$cur" = identity ]; then warn "V-274882 on $ME: OPEN - staged only, identity still writes"
  elif [ -z "$st" ]; then warn "V-274882 on $ME: OPEN - no config"
  else warn "V-274882 on $ME: OPEN - $run"; fi
  if [ -n "$cur" ] && [ "$cur" != identity ] && [ "$cur" != "gen$K8S_SECRETS_GEN" ]; then
    warn "this node writes with $cur, K8S_SECRETS_GEN is $K8S_SECRETS_GEN - a rotation in progress, or a stale parameter"
  fi
}

# What etcd ACTUALLY holds - the only proof. Every Secret's stored value is read through a pipe (never
# a file) and only its first bytes are looked at: k8s:enc:<provider>:v1:<key>: or plain. Exit 0 every
# Secret under the current key; 1 any plain or older; 2 THE CHECK DID NOT WORK - which proves nothing,
# so it is never reported as a pass (the lesson of the 2026-10-15 probe).
ENC_SCAN_PY="$(cat <<'PYEOF'
import base64, json, sys
want, api = sys.argv[1], int(sys.argv[2])
try:
    d = json.loads(sys.stdin.read())
except ValueError:
    print("  [x] etcd returned nothing readable"); sys.exit(2)
kvs = d.get("kvs") or []
by, plain, ver = {}, [], 0
for kv in kvs:
    name = base64.b64decode(kv["key"]).decode("utf-8", "replace")[len("/registry/secrets/"):]
    v = base64.b64decode(kv.get("value", ""))
    ver += int(kv.get("version", 0))
    if v.startswith(b"k8s:enc:"):
        p = b":".join(v.split(b":", 5)[:5]).decode("ascii", "replace") + ":"
        by[p] = by.get(p, 0) + 1
    else:
        plain.append(name)
print("  etcd holds %d Secrets; the API lists %d" % (len(kvs), api))
for p in sorted(by):
    print("    %-36s %5d%s" % (p, by[p], "   <- the current key" if p == want else "   <- NOT the current key: 'encrypt rewrite'"))
print("    %-36s %5d%s" % ("plain - NOT encrypted", len(plain), ("   e.g. " + ", ".join(plain[:4])) if plain else ""))
print("  writes to the Secrets that exist now, all keys: %d (a lower bound; aesgcm wants a new key before 200,000)" % ver)
if not kvs:
    print("  [x] no Secrets under /registry/secrets/ - the wrong prefix or the wrong etcd: this proves nothing"); sys.exit(2)
if abs(len(kvs) - api) > 5:
    print("  [x] etcd and the API disagree by more than churn - this is not reading what the API serves"); sys.exit(2)
print("RESULT total=%d plain=%d current=%d" % (len(kvs), len(plain), by.get(want, 0)))   # read by etcd-backup (G9)
sys.exit(0 if not plain and set(by) == {want} else 1)
PYEOF
)"

enc_scan() {
  local want api rc=0
  want="k8s:enc:$K8S_SECRETS_PROVIDER:v1:gen$K8S_SECRETS_GEN:"
  api="$( { kc get secrets -A -o name 2>/dev/null || true; } | wc -l)"
  say "every Secret in etcd, by how it is stored (the current key: $want)"
  ectl get /registry/secrets/ --prefix -w json 2>"$WORK/etcd.err" | python3 -c "$ENC_SCAN_PY" "$want" "$api" | grep -v '^RESULT ' || rc=$?
  case "$rc" in
    0) ok "V-274882: every Secret in etcd is encrypted with the current key" ;;
    1) die "V-274882: OPEN - Secrets above are plain or under an older key" ;;
    *) die "the check itself did not work: $(tail -2 "$WORK/etcd.err" 2>/dev/null | tr '\n' ' ')- it proves nothing either way" ;;
  esac
}

enc_rewrite() {
  local w="gen$K8S_SECRETS_GEN" want k a n name p out try
  want="k8s:enc:$K8S_SECRETS_PROVIDER:v1:$w:"
  [ "$(enc_field "$(enc_state)" write)" = "$w" ] || die "$ME does not write with $w - 'encrypt apply' on every control plane first"
  etcd_tools
  # PREFLIGHT: EVERY API server must already write with the current key, or the rewrite would store
  # part of the Secrets under the old one again - whichever server happened to take each write.
  say "preflight: a canary written through each control plane, read RAW from etcd"
  for k in $(grep -oE '^K8S_CP_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do
    a="${!k}"; n="$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')"; name="enclave-enc-rewrite-$n"
    kc --server="https://$a:6443" -n kube-system delete secret "$name" --ignore-not-found >/dev/null 2>&1 || true
    kc --server="https://$a:6443" -n kube-system create secret generic "$name" --from-literal=v=canary >/dev/null \
      || die "could not write a canary through $n - nothing was rewritten"
    p="$(ectl get "/registry/secrets/kube-system/$name" -w json 2>/dev/null | python3 -c '
import base64, json, sys
kv = (json.load(sys.stdin).get("kvs") or [{}])[0]
v = base64.b64decode(kv.get("value", ""))
print((b":".join(v.split(b":", 5)[:5]).decode("ascii", "replace") + ":") if v.startswith(b"k8s:enc:") else ("plain" if v else "missing"))' || true)"
    kc -n kube-system delete secret "$name" >/dev/null 2>&1 || true
    [ "$p" = "$want" ] || die "$n stores '${p:-nothing}', not $want - 'encrypt apply' on $n first; nothing was rewritten"
    ok "$n writes $want"
  done
  # THE REWRITE - Kubernetes' documented command: read every Secret and store it again. Through a pipe,
  # never a file - it carries every value. A Secret changed in between is a conflict: run again.
  for try in 1 2 3; do
    say "rewriting every Secret (attempt $try)"
    out="$(kc get secrets -A -o json | kc replace -f - 2>&1)" && break
    [ "$try" -lt 3 ] || die "the rewrite kept failing: $(printf '%s\n' "$out" | grep '^Error' | head -3 | cut -c1-200)"
    warn "$(printf '%s\n' "$out" | grep -c '^Error' || true) error(s), e.g. $(printf '%s\n' "$out" | grep '^Error' | head -1 | cut -c1-160) - again"
  done
  ok "$(printf '%s\n' "$out" | grep -c ' replaced$' || true) Secrets stored again"
  echo
  enc_scan
  ok "next: 'encrypt retire' on each control plane - the older key and the plain-text reader go"
}

cmd_encrypt() {
  need_root
  whoami_k8s
  [ "$ME_ROLE" = cp ] || die "Secrets are encrypted by the API servers - control planes only; this is $ME"
  enc_check_params
  local act="${1:-}" st cur w="gen$K8S_SECRETS_GEN"
  case "$act" in
    status)  enc_status; return 0 ;;
    check)   etcd_tools; enc_scan; return 0 ;;
    rewrite) enc_rewrite; return 0 ;;
    stage|apply|retire) ;;
    *) die "usage: encrypt status|check|stage|apply|rewrite|retire - the order is in docs/07-kubernetes.md 3.12" ;;
  esac
  /snap/bin/k8s status >/dev/null 2>&1 || die "$ME is not in a running cluster - a NEW control plane gets its config from node-prep"
  enc_ready || die "cannot read https://$ME_ADDR:6443/readyz with the admin kubeconfig BEFORE changing anything - the check this relies on does not work here; nothing changed"
  enc_peers_ready
  st="$(enc_state)"; cur="$(enc_field "$st" write)"
  ENC_CHANGED=0
  if [ "$act" = stage ]; then
    if [ "$cur" = "$w" ]; then ok "$ME already writes with $w - nothing to stage"; enc_status; return 0; fi
    enc_write_config derive "${cur:-identity}"
  elif [ "$act" = retire ]; then
    [ "$cur" = "$w" ] || die "$ME does not write with $w - 'apply' and 'rewrite' first"
    # Removing the plain-text reader is safe ONLY if nothing plain is left - etcd, read raw, decides.
    etcd_tools
    enc_scan
    enc_write_config retire "$w"
  else
    case ",$(enc_field "$st" keys)," in *",$w,"*) ;; *) die "$w is not staged on $ME - 'encrypt stage' first, on EVERY control plane" ;; esac
    enc_write_config reorder "$w"
  fi
  enc_args_ensure
  if [ "$ENC_CHANGED" = 1 ] || [ "$(enc_running)" != yes ]; then enc_restart
  else ok "the running API server already has this config - no restart"; fi
  echo
  if [ "$act" = stage ] || [ "$act" = retire ]; then
    # PROOF: a list fails outright if a single Secret cannot be decrypted. Names only, to a file.
    kc --server="https://$ME_ADDR:6443" get secrets -A -o name > "$WORK/secrets.list" 2>"$WORK/list.err" \
      || die "this API server cannot list the Secrets: $(tail -1 "$WORK/list.err")"
    if [ "$act" = stage ]; then
      ok "this API server reads all $(wc -l < "$WORK/secrets.list") Secrets; $w is held here, not yet used for writing"
      ok "staged on $ME. Next: 'encrypt stage' on the other control planes - only when ALL are staged, 'encrypt apply' on each"
    else
      ok "this API server reads all $(wc -l < "$WORK/secrets.list") Secrets with $w alone - no older key, no plain-text reader"
      ok "retired on $ME. Next: 'encrypt retire' on the other control planes"
    fi
  else
    say "canary: a Secret written through $ME, read back through every control plane"
    enc_canary || die "read the lines above. CANNOT DECRYPT: run 'encrypt stage' on that control plane NOW - until then it cannot read Secrets written here. DID NOT ANSWER: it was restarting; when it is ready, run 'encrypt apply' here again (no restart - it repeats the canary)"
    ok "$ME writes with $w. Next: 'encrypt apply' on the other control planes, then 'encrypt rewrite' on one"
  fi
}

# ===================================================================== nightly etcd backups (G9)
# THE CLUSTER'S STATE, OFF THE CLUSTER, EVERY NIGHT (backlog B-07 G9; decided 2026-10-16, Brian).
# Nothing else backs etcd up: hosts 1-3 run no VM backups at all (backlog 3.68), so without this the
# loss of the three control planes would lose every Deployment, Service, ConfigMap and Secret.
#
#   WHO: every control plane's timer fires; the one holding the API VIP backs up, the others only keep
#     their record - once a night, and it moves with the VIP (the same rule as G10's cluster check).
#   WHAT: etcdctl snapshot save -> etcdutl snapshot status -> RESTORED into a scratch directory, so
#     every night proves the snapshot is usable -> the newest K8S_ETCD_BACKUP_KEEP kept here -> pushed
#     to EACH store in K8S_ETCD_STORES (D1 A: two stores, like pgBackRest's) -> the Secrets-at-rest
#     scan of 3.64 -> the result published for Prometheus.
#   NO EXTRA ENCRYPTION (D2 A): the Secrets inside are AES-GCM with a key that never leaves the control
#     planes (3.64), both stores are LUKS, and the rest is cluster configuration, not records.
#   THE TOOLS (D3, accepted): etcd's own etcdctl/etcdutl, upstream Go, NOT FIPS - Canonical ships none.
#     Nightly use makes the drill's tool a routine one (POA&M ENG-77). etcdctl speaks only to
#     127.0.0.1; the snapshot leaves over ssh (FIPS). Verified once from the mirror, then kept root-only
#     in K8S_ETCD_TOOLS_CACHE and re-checked against their checksums every night, so a backup does not
#     depend on svc-repo-01 being up.
#   THE STORES authorise this node's key for a WRITE-ONLY rsync into ONE directory, <dir>/<this node>
#     (`etcd-backup --setup` prints exactly what to run there) - one node's retention can never delete
#     another's snapshots. A store whose volume is not mounted has no such directory, so the push fails
#     loudly instead of filling the root filesystem.
K8S_ETCD_BACKUP_DIR="${K8S_ETCD_BACKUP_DIR:-/var/backups/etcd}"
K8S_ETCD_BACKUP_KEEP="${K8S_ETCD_BACKUP_KEEP:-14}"
K8S_ETCD_BACKUP_AT="${K8S_ETCD_BACKUP_AT:-06:00}"     # UTC; before host-4's 07:00 VM backup, which uses the same volume
# The stores are declared once, in vm-specs.env (ETCD_BACKUP_STORES, from BACKUP_DEST). Only those two
# lines are read: sourcing the whole file here would run its profile detection, which warns falsely on
# a control plane (it has /etc/enclave and no profile).
if [ -z "${K8S_ETCD_STORES:-}" ] && [ -r "$ENC/vm-specs.env" ]; then
  # shellcheck disable=SC2034  # BACKUP_DEST is read by the eval'd ETCD_BACKUP_STORES line
  K8S_ETCD_STORES="$(BACKUP_DEST=""; eval "$(sed -n -e '/^BACKUP_DEST=/p' -e '/^ETCD_BACKUP_STORES=/p' "$ENC/vm-specs.env")"; printf '%s' "${ETCD_BACKUP_STORES:-}")"
fi
[ -n "${K8S_ETCD_STORES:-}" ] || K8S_ETCD_STORES="host-4:/mnt/vmbackup/etcd host-3:/var/lib/libvirt/images/etcd-backup"
K8S_ETCD_BACKUP_KEY="${K8S_ETCD_BACKUP_KEY:-/etc/enclave/etcd-backup.key}"
K8S_ETCD_TOOLS_CACHE="${K8S_ETCD_TOOLS_CACHE:-/var/lib/enclave-etcd-tools}"
K8S_TEXTFILE_DIR="${K8S_TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
EB_FACTS="$K8S_TEXTFILE_DIR/k8s-etcd-backup.prom"

eb_store_addr() {   # <store host name> -> its address from enclave-addresses.env
  local k; k="$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
  [[ "$k" =~ ^[A-Z0-9_]+$ ]] || return 0
  printf '%s' "${!k:-}"
}

# eb_carry NAME [LABELS] -> the value this node last published for a metric, or nothing
eb_carry() {
  local key="$1"; [ -z "${2:-}" ] || key="$1{$2}"
  [ -r "$EB_FACTS" ] && awk -v n="$key" '$1 == n {print $2; exit}' "$EB_FACTS" || true
}

# eb_facts KEY=VALUE... -> rewrite this node's facts file whole, atomically. Values not given are
# CARRIED (last success times), so a night as a non-holder, or a failed night, keeps the history and
# drops nothing but the current-state numbers it does not have.
eb_m() {   # NAME VALUE HELP - one gauge with its HELP and TYPE; nothing when the value is empty
  [ -n "$2" ] || return 0
  printf '# HELP %s %s\n# TYPE %s gauge\n%s %s\n' "$1" "$3" "$1" "$1" "$2"
}
eb_facts() {
  [ -d "$K8S_TEXTFILE_DIR" ] || { warn "no $K8S_TEXTFILE_DIR - node-exporter not installed (monitoring.sh exporter); nothing published"; return 0; }
  local -A v=(); local kv s ls
  for kv in "$@"; do v["${kv%%=*}"]="${kv#*=}"; done
  ls="${v[last_success]:-$(eb_carry enclave_k8s_etcd_backup_last_success_seconds)}"
  {
    printf '# HELP enclave_k8s_etcd_backup_last_success_seconds when this node last made a snapshot that restored (G9)\n'
    printf '# TYPE enclave_k8s_etcd_backup_last_success_seconds gauge\n'
    [ -z "$ls" ] || printf 'enclave_k8s_etcd_backup_last_success_seconds %s\n' "$ls"
    printf '# HELP enclave_k8s_etcd_backup_store_last_success_seconds when this node last pushed its snapshots to a store\n'
    printf '# TYPE enclave_k8s_etcd_backup_store_last_success_seconds gauge\n'
    for s in $K8S_ETCD_STORES; do
      s="${s%%:*}"
      ls="${v[store_ok_$s]:-$(eb_carry enclave_k8s_etcd_backup_store_last_success_seconds "store=\"$s\"")}"
      [ -z "$ls" ] || printf 'enclave_k8s_etcd_backup_store_last_success_seconds{store="%s"} %s\n' "$s" "$ls"
    done
    # CURRENT STATE - only from the node that ran tonight, so a former holder's stale numbers vanish
    if [ -n "${v[run]:-}" ]; then
      eb_m enclave_k8s_etcd_backup_last_run_seconds "${v[run]}" "when this node last ran the backup as the VIP holder"
      eb_m enclave_k8s_etcd_backup_last_run_ok "${v[ok]:-0}" "1 when that run reached every store"
      eb_m enclave_k8s_etcd_backup_revision "${v[revision]:-}" "etcd revision in the newest snapshot"
      eb_m enclave_k8s_etcd_backup_keys "${v[keys]:-}" "keys in the newest snapshot"
      eb_m enclave_k8s_etcd_backup_bytes "${v[bytes]:-}" "size of the newest snapshot"
      eb_m enclave_k8s_etcd_backup_local_snapshots "${v[local_count]:-}" "snapshots kept on this node"
      if [ -n "${v[sec_ok]:-}" ]; then
        eb_m enclave_k8s_secrets_check_ok "${v[sec_ok]}" "1 when the nightly scan of etcd could be trusted (3.64)"
        eb_m enclave_k8s_secrets_in_etcd "${v[sec_total]:-}" "Secrets in etcd at the nightly scan"
        [ -z "${v[sec_plain]:-}" ] || printf '# HELP enclave_k8s_secrets_plain_in_etcd Secrets stored NOT encrypted - V-274882\n# TYPE enclave_k8s_secrets_plain_in_etcd gauge\nenclave_k8s_secrets_plain_in_etcd %s\n' "${v[sec_plain]}"
      fi
    fi
  } > "$EB_FACTS.tmp"
  chmod 0644 "$EB_FACTS.tmp"; mv -f "$EB_FACTS.tmp" "$EB_FACTS"
}

etcd_backup_setup() {
  local s name dir addr myaddr line kb
  [ -s "$K8S_ETCD_BACKUP_KEY" ] || {
    install -d -m 0700 "$(dirname "$K8S_ETCD_BACKUP_KEY")"
    # RSA, not ed25519: FIPS ssh-keygen refuses ed25519 (measured on host-4, 2026-09-20).
    ssh-keygen -t rsa -b 4096 -N '' -C "etcd-backup from $ME" -f "$K8S_ETCD_BACKUP_KEY" >/dev/null || die "ssh-keygen failed"
    ok "created $K8S_ETCD_BACKUP_KEY"; }
  kb="$(cut -d' ' -f2 "$K8S_ETCD_BACKUP_KEY.pub")"
  say "this node's backup key: $(ssh-keygen -lf "$K8S_ETCD_BACKUP_KEY.pub" | awk '{print $2}')"
  for s in $K8S_ETCD_STORES; do
    name="${s%%:*}"; dir="${s#*:}/$ME"; addr="$(eb_store_addr "$name")"
    [ -n "$addr" ] || die "no address for store $name in $ADDRS"
    myaddr="$(ip -4 route get "$addr" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
    [ -n "$myaddr" ] || die "cannot tell which address $ME uses to reach $addr"
    line="from=\"$myaddr\",restrict,command=\"/usr/bin/rrsync -wo $dir\" $(cut -d' ' -f1-2 "$K8S_ETCD_BACKUP_KEY.pub")"
    printf '\n  ON %s - authorise %s'"'"'s etcd backups, ONCE (a WRITE-ONLY rsync into %s):\n\n' "$name" "$ME" "$dir"
    printf '### MACHINE: %s (%s) ###\n' "$name" "$addr"
    printf 'if [ "$(hostname -s)" != %s ]; then echo "WRONG MACHINE: $(hostname -s)"; else\n' "$name"
    # THE PARENT, which exists mounted or not: the store directory itself does not exist yet, and
    # findmnt on a missing path prints nothing - which must read as NOT mounted, never as mounted.
    printf '  t="$(findmnt -no TARGET --target %s 2>/dev/null)"\n' "$(dirname "${s#*:}")"
    printf '  if [ -z "$t" ] || [ "$t" = / ]; then echo "%s is not on its own mounted volume - nothing done"; else\n' "$(dirname "${s#*:}")"
    printf '    ls -l /usr/bin/rrsync && sudo install -d -m 0700 -o root -g root %s %s \\\n' "${s#*:}" "$dir"
    printf '    && { sudo grep -qF %s /root/.ssh/authorized_keys 2>/dev/null || echo %s | sudo tee -a /root/.ssh/authorized_keys >/dev/null; } \\\n' "'$kb'" "'$line'"
    printf '    && sudo chmod 600 /root/.ssh/authorized_keys && echo "authorised %s -> %s"\n' "$ME" "$dir"
    printf '  fi\nfi\n'
  done
  printf '\n'
  say "then here: sudo $0 etcd-backup --force   (one backup now, whoever holds the VIP), then sudo $0 etcd-backup --timer"
}

etcd_backup_timer() {
  "$ENC/install-runtime.sh" || die "could not install the root-owned runtime copy"
  local rt; rt="$("$ENC/install-runtime.sh" --print-dir)"
  [ -x "$rt/07-kubernetes.sh" ] || die "$rt/07-kubernetes.sh missing - install-runtime.sh must copy it (G9)"
  case "$K8S_ETCD_BACKUP_AT" in [0-2][0-9]:[0-5][0-9]) ;; *) die "K8S_ETCD_BACKUP_AT wants HH:MM, got '$K8S_ETCD_BACKUP_AT'" ;; esac
  cat > /etc/systemd/system/enclave-etcd-backup.service <<UNIT
[Unit]
Description=Nightly etcd snapshot, restore-tested and pushed off the cluster (B-07 G9)
After=network-online.target snap.k8s.etcd.service

[Service]
Type=oneshot
TimeoutStartSec=30min
ExecStart=$rt/07-kubernetes.sh etcd-backup
UNIT
  # Calendar, like every enclave timer (a monotonic chain lost its place across a reboot, 2026-09-16).
  # Persistent: a night missed while this node was down runs when it comes back - and re-creating
  # the timer can start a run at once (measured on host-4's backup timer, 2026-10-15).
  cat > /etc/systemd/system/enclave-etcd-backup.timer <<UNIT
[Unit]
Description=Nightly etcd backup at $K8S_ETCD_BACKUP_AT UTC (the VIP holder acts)

[Timer]
OnCalendar=*-*-* $K8S_ETCD_BACKUP_AT:00 UTC
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now enclave-etcd-backup.timer >/dev/null 2>&1 || die "could not enable enclave-etcd-backup.timer"
  ok "enclave-etcd-backup.timer at $K8S_ETCD_BACKUP_AT UTC, running $rt/07-kubernetes.sh ($(head -1 "$rt/.source"))"
  systemctl list-timers enclave-etcd-backup.timer --no-pager 2>/dev/null | sed -n 2p | sed 's/^/     /'
}

cmd_etcd_backup() {
  need_root
  whoami_k8s
  [ "$ME_ROLE" = cp ] || die "etcd backups run on the control planes - this is $ME"
  local mode="${1:-}"
  case "$mode" in
    --setup) etcd_backup_setup; return 0 ;;
    --timer) etcd_backup_timer; return 0 ;;
    ""|--force) ;;
    *) die "usage: etcd-backup [--setup | --force | --timer]" ;;
  esac
  if [ "$mode" != --force ] && ! ip -4 -o addr show | grep -q " ${K8S_API_VIP:?}/"; then
    eb_facts; ok "$ME does not hold the API VIP - the holder backs up tonight; this node's record kept"; return 0
  fi
  [ -s "$K8S_ETCD_BACKUP_KEY" ] || die "no key at $K8S_ETCD_BACKUP_KEY - run: sudo $0 etcd-backup --setup"
  local run; run="$(date +%s)"
  local failed=""

  etcd_tools "$K8S_ETCD_TOOLS_CACHE"   # dies if no verified tools - the stale-backup alert then says so
  install -d -m 0700 -o root -g root "$K8S_ETCD_BACKUP_DIR"
  local f out rev keys bytes
  f="$K8S_ETCD_BACKUP_DIR/etcd-$(date -u +%Y%m%dT%H%M%SZ)-$ME.db"
  # 1. the snapshot - written as .part, renamed only when whole
  out="$(ectl snapshot save "$f.part" 2>&1)" || { rm -f "$f.part"; eb_facts run="$run" ok=0; die "snapshot failed: $(printf '%s' "$out" | tail -2)"; }
  chmod 0600 "$f.part"; mv -f "$f.part" "$f"
  # 2. what is in it
  out="$("$ETCD_BIN/etcdutl" snapshot status "$f" -w json 2>&1 | tail -1)" || { eb_facts run="$run" ok=0; die "snapshot status failed: $out"; }
  read -r rev keys bytes <<<"$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["revision"], d["totalKey"], d["totalSize"])' 2>/dev/null)" \
    || { eb_facts run="$run" ok=0; die "could not read the snapshot status: $out"; }
  ok "snapshot $(basename "$f"): revision $rev, $keys keys, $(( bytes / 1048576 )) MB"
  # 3. RESTORED - into scratch, with a throwaway member; the live data directory is never named
  out="$("$ETCD_BIN/etcdutl" snapshot restore "$f" --data-dir "$WORK/restore" --name g9-test \
         --initial-cluster g9-test=http://127.0.0.1:12380 --initial-advertise-peer-urls http://127.0.0.1:12380 2>&1)" \
    || { eb_facts run="$run" ok=0; die "THE SNAPSHOT DOES NOT RESTORE: $(printf '%s' "$out" | tail -2)"; }
  [ -s "$WORK/restore/member/snap/db" ] || { eb_facts run="$run" ok=0; die "restore reported success but wrote no member/snap/db"; }
  shred -u "$WORK/restore/member/snap/db"
  ok "restored into scratch and discarded - tonight's snapshot is usable"
  # 4. keep the newest K8S_ETCD_BACKUP_KEEP here; half-written ones from a crash go too
  find "$K8S_ETCD_BACKUP_DIR" -maxdepth 1 -name 'etcd-*.db.part' -mmin +60 -delete
  local n=0 old
  while IFS= read -r old; do
    n=$((n + 1)); [ "$n" -le "$K8S_ETCD_BACKUP_KEEP" ] || rm -f "$old"
  done < <(find "$K8S_ETCD_BACKUP_DIR" -maxdepth 1 -name 'etcd-*.db' | sort -r)
  local count; count="$(find "$K8S_ETCD_BACKUP_DIR" -maxdepth 1 -name 'etcd-*.db' | wc -l)"
  # 5. off the cluster - each store on its own; one failing does not stop the other
  local -a sargs=(); local s name addr rc
  for s in $K8S_ETCD_STORES; do
    name="${s%%:*}"; addr="$(eb_store_addr "$name")"
    if [ -z "$addr" ]; then warn "store $name: no address in $ADDRS"; failed="$failed $name"; continue; fi
    rc=0
    out="$(rsync -a --delete --include='etcd-*.db' --exclude='*' \
           -e "ssh -i $K8S_ETCD_BACKUP_KEY -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR" \
           "$K8S_ETCD_BACKUP_DIR/" "root@$addr:" 2>&1 </dev/null)" || rc=$?
    if [ "$rc" -eq 0 ]; then ok "store $name ($addr): $count snapshot(s) in place"; sargs+=("store_ok_$name=$(date +%s)")
    else warn "store $name ($addr) FAILED (rsync rc $rc): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"; failed="$failed $name"; fi
  done
  # 6. the Secrets-at-rest scan of 3.64, every night - V-274882 watched, not assumed
  local want sec_ok=0 sec_total="" sec_plain="" res
  want="k8s:enc:$K8S_SECRETS_PROVIDER:v1:gen$K8S_SECRETS_GEN:"
  res="$( { ectl get /registry/secrets/ --prefix -w json 2>/dev/null \
           | python3 -c "$ENC_SCAN_PY" "$want" "$( { kc get secrets -A -o name 2>/dev/null || true; } | wc -l)" || true; } | sed -n 's/^RESULT //p')"
  if [ -n "$res" ]; then
    sec_ok=1; sec_total="$(printf '%s\n' "$res" | tr ' ' '\n' | sed -n 's/^total=//p')"; sec_plain="$(printf '%s\n' "$res" | tr ' ' '\n' | sed -n 's/^plain=//p')"
    if [ "${sec_plain:-1}" -eq 0 ]; then ok "Secrets at rest: $sec_total in etcd, none plain"; else warn "Secrets at rest: $sec_plain of $sec_total stored PLAIN - V-274882"; fi
  else warn "the Secrets scan did not work tonight - it proves nothing either way"; fi
  local good=1; [ -z "$failed" ] || good=0
  eb_facts run="$run" ok="$good" last_success="$run" revision="$rev" keys="$keys" bytes="$bytes" local_count="$count" \
           sec_ok="$sec_ok" sec_total="$sec_total" sec_plain="$sec_plain" "${sargs[@]}"
  [ -z "$failed" ] || die "the snapshot is good and kept here, but did not reach:$failed"
  ok "etcd backup done on $ME - $count kept here, and on every store"
}

# ===================================================================== the API VIP
# keepalived, VRRP UNICAST between the three control planes (runbook 3.0a: keepalived, not kube-vip;
# the ufw rows for VRRP exist since A3). The VIP is for clients OUTSIDE the cluster - kubectl from
# svc-mgmt-01, Prometheus on svc-obs-01. Inside, each worker's k8s-apiserver-proxy already spreads
# over all three API servers, so the cluster does not depend on the VIP.
K8S_VRRP_ID="${K8S_VRRP_ID:-${K8S_API_VIP##*.}}"     # 1-255, unique on the segment; default the VIP's last octet
KA_CONF="${KA_CONF:-/etc/keepalived/keepalived.conf}"
KA_CHECK="${KA_CHECK:-/etc/keepalived/k8s-api-check.sh}"

# THE HEALTH CHECK HAS NO CREDENTIALS, deliberately. Anonymous access is off (STIG), so a healthy
# API server answers an unauthenticated /livez with 401; 401 or 200 is "up", a refused or timed-out
# connection is "down" - what a crashed API server looks like. Handing keepalived the admin
# kubeconfig would put the cluster's strongest credential in use every 3 s and write every probe
# to the audit log at RequestResponse. What it does not catch: an API server that runs but has
# lost etcd - which is a cluster-wide event that moving the VIP would not fix.
ka_check() {
cat <<'EOF'
#!/bin/sh
# 07-kubernetes.sh vip - keepalived holds the API VIP only on a node whose own API server answers.
code="$(curl -sk --max-time 2 -o /dev/null -w '%{http_code}' https://127.0.0.1:6443/livez)"
[ "$code" = 401 ] || [ "$code" = 200 ]
EOF
}

ka_conf() {  # IFACE PRIO PEERS...
  local iface="$1" prio="$2"; shift 2
  local p
  cat <<EOF
# keepalived.conf - written by 07-kubernetes.sh vip on $ME (backlog B-07). The Kubernetes API VIP.
global_defs {
    router_id $ME
    enable_script_security
    script_user root
}
vrrp_script k8s_api {
    script "$KA_CHECK"
    interval 3
    timeout 3
    fall 2
    rise 2
}
vrrp_instance K8S_API {
    state BACKUP
    nopreempt
    interface $iface
    virtual_router_id $K8S_VRRP_ID
    priority $prio
    advert_int 1
    unicast_src_ip $ME_ADDR
    unicast_peer {
EOF
  for p in "$@"; do printf '        %s\n' "$p"; done
  cat <<EOF
    }
    virtual_ipaddress {
        $K8S_API_VIP/24 dev $iface
    }
    track_script {
        k8s_api
    }
}
EOF
}

cmd_vip() {
  need_root
  whoami_k8s
  [ "$ME_ROLE" = cp ] || die "the API VIP lives on the control planes - this is $ME"
  [ -n "${K8S_API_VIP:-}" ] || die "no K8S_API_VIP in $ADDRS"
  case "$K8S_VRRP_ID" in ''|*[!0-9]*) die "K8S_VRRP_ID='$K8S_VRRP_ID' is not 1-255" ;; esac
  if [ "$K8S_VRRP_ID" -lt 1 ] || [ "$K8S_VRRP_ID" -gt 255 ]; then die "K8S_VRRP_ID=$K8S_VRRP_ID is not 1-255"; fi
  # The interface that holds this node's address - found, never named.
  local iface; iface="$(ip -o -4 addr show | awk -v a="$ME_ADDR" '{split($4, x, "/"); if (x[1] == a) print $2}' | head -1)"
  [ -n "$iface" ] || die "no interface holds $ME_ADDR"
  # Priority by control-plane number: cp-01 130, cp-02 120, cp-03 110. With nopreempt the holder
  # keeps the VIP when a higher one returns - one move per failure, not two.
  local n prio peers=() k
  n="${ME##*-}"; n=$((10#$n)); prio=$((140 - 10 * n))
  for k in $(grep -oE '^K8S_CP_[0-9]+=' "$ADDRS" | tr -d '=' | sort); do [ "${!k}" = "$ME_ADDR" ] || peers+=("${!k}"); done
  [ "${#peers[@]}" -ge 1 ] || die "no other control planes in $ADDRS"
  say "vip         $K8S_API_VIP on $iface - VRRP id $K8S_VRRP_ID, priority $prio, unicast to ${peers[*]}"

  if ! command -v keepalived >/dev/null 2>&1; then
    # --no-install-recommends: nothing optional on a hardened guest. keepalived still DEPENDS on
    # net-snmp's libraries, which bring Perl (~1-2 min to unpack here) - seen on cp-01 2026-10-14.
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends keepalived >/dev/null || die "apt-get install keepalived failed - is apt pointed at the mirror?"
    ok "keepalived installed ($(keepalived --version 2>&1 | head -1))"
  else ok "keepalived already installed ($(keepalived --version 2>&1 | head -1))"; fi
  ka_check | install_if_changed "$KA_CHECK" 0755
  local before=""; [ -f "$KA_CONF" ] && before="$(sha256sum "$KA_CONF")"
  ka_conf "$iface" "$prio" "${peers[@]}" | install_if_changed "$KA_CONF" 0644
  keepalived -t -f "$KA_CONF" >/dev/null 2>"$WORK/ka.err" || die "keepalived rejects the config: $(cat "$WORK/ka.err")"
  systemctl enable keepalived >/dev/null 2>&1
  if [ "$before" != "$(sha256sum "$KA_CONF")" ] || ! systemctl is-active --quiet keepalived; then
    systemctl restart keepalived || die "keepalived did not start - journalctl -u keepalived"
    ok "keepalived (re)started"
  else ok "keepalived running, config unchanged"; fi
  if "$KA_CHECK"; then ok "health check: the local API server answers"; else warn "health check FAILS here - this node will not take the VIP"; fi
  sleep 5
  if ip -o -4 addr show dev "$iface" | grep -q " $K8S_API_VIP/"; then ok "THIS node holds the VIP $K8S_API_VIP"
  else say "this node is standby - the VIP is on another control plane (or none yet: run vip on all three)"; fi
  local code; code="$(curl -sk --max-time 3 -o /dev/null -w '%{http_code}' "https://$K8S_API_VIP:6443/livez" 2>&1 || true)"
  case "$code" in 401|200) ok "the API answers on the VIP: https://$K8S_API_VIP:6443 (HTTP $code - anonymous is off)" ;;
                  *) warn "no API answer on the VIP yet (HTTP ${code:-none}) - expected until a control plane holds it" ;; esac
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

  # ---- 6. Secrets at rest (V-274882, backlog 3.64) - this node's API server; what etcd holds: encrypt check
  echo; say "== 6. Secrets encrypted at rest (V-274882)"
  local est ew er
  est="$(enc_state)"; ew="$(enc_field "$est" write)"; er="$(enc_running)"
  if [ "$er" = yes ] && [ -n "$ew" ] && [ "$ew" != identity ]; then vok "this API server writes Secrets with $ew ($(enc_field "$est" provider)) - etcd itself: encrypt check"
  else vbad "this API server does NOT encrypt Secrets: ${est:-no config at $K8S_ENC_CONFIG}; running: $er (07-kubernetes.md 3.12)"; fi

  echo
  [ "$V_FAIL" -eq 0 ] || die "$V_FAIL check(s) failed - read the [x] lines above"
  ok "all $V_PASS checks passed - the test workload stays up in $V_NS (verify --cleanup removes it)"
}

case "${1:-}" in
  vip)           shift; cmd_vip "$@" ;;
  probe)         shift; cmd_probe "$@" ;;
  etcd-drill)    shift; cmd_etcd_drill "$@" ;;
  encrypt)       shift; cmd_encrypt "$@" ;;
  etcd-backup)   shift; cmd_etcd_backup "$@" ;;
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
  *) sed -n '2,67p' "$0"; exit 2 ;;
esac
