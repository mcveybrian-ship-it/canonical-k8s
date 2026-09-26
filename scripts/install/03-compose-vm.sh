#!/usr/bin/env bash
# =========================================================================================
# 03-compose-vm.sh - compose one enclave VM from the Minimal cloud image.
#
#     MACHINE: runs ON the virtualisation host (host-4 for the service VMs).
#     It REFUSES a guest whose PLACE_<GUEST> in vm-specs.env names another host (backlog 2.7).
#
#     sudo ./03-compose-vm.sh svc-mgmt-01
#     sudo ./03-compose-vm.sh svc-mgmt-01 -n        show what it would do, touch nothing
#     sudo ./03-compose-vm.sh svc-mgmt-01 --destroy remove it and its disk
#     ./03-compose-vm.sh plan                       does THIS host fit the guests mapped to it
#     ./03-compose-vm.sh plan --spec                what each host must have - no hardware
#
# There are ten of these to build, so it is a composer rather than a one-off. Everything
# comes from two files and nothing is typed twice:
#     scripts/enclave/enclave-addresses.env   who is at which address
#     scripts/enclave/vm-specs.env            cpu / ram / disk / image / mirror
#
# WHY THE CLOUD IMAGE AND NOT THE SERVER ISO:
#   A cloud image needs no installer, so composing a VM is one command that either works or
#   does not - no autoinstall to debug, no console to watch. The runbook asked for "standard
#   server" on the service VMs for diagnostic tooling; VM_EXTRA_PACKAGES names that tooling
#   explicitly, which produces the same ability from an auditable list rather than from
#   whatever an ISO happened to ship. Better evidence for the same outcome.
#
# The VM gets NO DEFAULT ROUTE, like its host. It reaches 10.0.20.0/24 and nothing else.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENCLAVE_DIR="${ENCLAVE_DIR:-$SELF/../enclave}"
DRY=0; DESTROY=0; VM=""; PLAN_ARG=""

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" -eq 1 ]; then echo "  DRY: $*"; else "$@"; fi; }


# =========================================================================================
# plan - what runs where, and does it fit.  backlog 2.7.
#
#     ./03-compose-vm.sh plan            VERIFY: measures THIS host, checks its guests fit
#     ./03-compose-vm.sh plan --spec     SPEC:   no hardware needed, prints the requirement
#
# VERIFY is the gate before composing anything: it reads threads, RAM and free space FROM THE
# MACHINE and refuses a layout that does not fit, instead of finding out on the fourth guest.
# SPEC runs anywhere, including before the hardware exists - it turns the map into the BOM
# argument (RAM per host, devices per host) rather than an estimate.
#
# IT RECOMMENDS AND VERIFIES. It never moves a guest or rewrites the map: an algorithm quietly
# reshuffling guests between sites is the opposite of a repeatable build.
# =========================================================================================
plan_hosts() {   # every host named by the map, in order
  local v; for v in $(compgen -A variable PLACE_ 2>/dev/null); do
    case "$v" in PLACE_BACKUP_SECOND) continue ;; esac
    printf '%s\n' "${!v}"
  done | sort -u
}
plan_guests_on() {  # guests the map places on $1
  local host="$1" v g; for v in $(compgen -A variable PLACE_ 2>/dev/null); do
    case "$v" in PLACE_BACKUP_SECOND) continue ;; esac
    [ "${!v}" = "$host" ] || continue
    g="$(echo "${v#PLACE_}" | tr 'A-Z_' 'a-z-')"
    [ -n "${!v}" ] && printf '%s\n' "$g"
  done | sort
}
plan_sum() {  # <host> -> "vcpu ram_mb disk_gb data_gb count", from the specs
  local host="$1" g sv vc rm dk dt; local tv=0 tr=0 td=0 tdd=0 n=0
  for g in $(plan_guests_on "$host"); do
    sv="VM_$(echo "$g" | tr 'a-z-' 'A-Z_')"; [ -n "${!sv:-}" ] || continue
    IFS=: read -r vc rm dk dt <<< "${!sv}"
    tv=$((tv+vc)); tr=$((tr+rm)); td=$((td+dk)); tdd=$((tdd+${dt:-0})); n=$((n+1))
  done
  printf '%s %s %s %s %s' "$tv" "$tr" "$td" "$tdd" "$n"
}

cmd_plan() {
  local spec=0; [ "${1:-}" = --spec ] && spec=1
  local me; me="$(hostname -s)"
  local reserve="${HOST_RESERVE_MB:-4096}" fail=0
  printf '\n  PLACEMENT PLAN - VM_PROFILE=%s\n\n' "$VM_PROFILE"

  local h vc rm dk dt n
  printf '  %-8s %-5s %-9s %-10s %-9s %s\n' HOST GUESTS vCPU RAM DISK "guests"
  for h in $(plan_hosts); do
    read -r vc rm dk dt n <<< "$(plan_sum "$h")"
    printf '  %-8s %-5s %-9s %-10s %-9s %s\n' "$h" "$n" "$vc" \
      "$(( (rm + reserve) / 1024 )) GiB" "$(( dk + dt )) GB" "$(plan_guests_on "$h" | tr '\n' ' ')"
  done
  printf '\n  RAM includes %s MiB reserved for each host itself.\n' "$reserve"
  printf '  DISK is the qcow2 CEILING, deliberately over-committed - the disks are sparse.\n'

  # ---- rules that hold whatever the hardware is -----------------------------------------
  printf '\n  RULES\n'
  local grp m seen dup
  IFS='|' read -ra GRPS <<< "${ANTI_AFFINITY:-}"
  for grp in "${GRPS[@]:-}"; do
    [ -n "$grp" ] || continue
    seen=""; dup=""
    for m in $grp; do
      h="$(vm_place "$m")"; [ -n "$h" ] || continue
      case " $seen " in *" $h "*) dup="$dup $m@$h" ;; esac
      seen="$seen $h"
    done
    if [ -n "$dup" ]; then
      warn "anti-affinity BROKEN for [$grp ] -$dup"; fail=1
    else
      ok "anti-affinity holds: $grp"
    fi
  done
  local second="${PLACE_BACKUP_SECOND:-}"
  if [ -z "$second" ]; then
    warn "no PLACE_BACKUP_SECOND - the backups have no copy off their own host (red flag 1.2)"; fail=1
  elif [ "$second" = ring ]; then
    # Each host's second copy goes to the next host, the last wrapping to the first. Every
    # guest then has a copy on a machine that is not the one running it.
    local -a ring=(); while read -r h; do [ -n "$(plan_guests_on "$h")" ] && ring+=("$h"); done < <(plan_hosts)
    if [ "${#ring[@]}" -lt 2 ]; then
      warn "PLACE_BACKUP_SECOND=ring needs at least two hosts running guests - name a host instead"; fail=1
    else
      local i nxt line=""
      for i in "${!ring[@]}"; do
        nxt="${ring[$(( (i+1) % ${#ring[@]} ))]}"
        line="$line ${ring[$i]}->$nxt"
      done
      ok "backup ring:$line"
    fi
  else
    local stranded; stranded="$(plan_guests_on "$second" | tr '\n' ' ')"
    if [ -n "$stranded" ]; then
      warn "second backup copy is on $second, which also RUNS: $stranded - those guests have no off-host copy"; fail=1
    else
      ok "second backup copy on $second, which runs no guests"
    fi
  fi

  [ "$spec" -eq 1 ] && { printf '\n  SPEC MODE - no hardware was measured. Per host, the design needs:\n'
    printf '    RAM     the figure above, and the drives below are a CHASSIS decision:\n'
    printf '    devices OS (mirrored pair) - etcd - database data - one per Ceph OSD - VM pool\n'
    printf '            ~6 drives per host; see backlog 2.8\n\n'; return 0; }

  # ---- verify against THIS machine ------------------------------------------------------
  read -r vc rm dk dt n <<< "$(plan_sum "$me")"
  printf '\n  VERIFY - %s, measured now\n' "$me"
  if [ "$n" -eq 0 ]; then
    say "the map places no guest on $me - nothing to check here"; printf '\n'; return 0
  fi
  local have_threads have_ram_mb
  have_threads="$(nproc)"
  have_ram_mb="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
  local need_ram=$(( rm + reserve ))
  if [ "$need_ram" -le "$have_ram_mb" ]; then
    ok "RAM: need $((need_ram/1024)) GiB (guests + reserve), have $((have_ram_mb/1024)) GiB"
  else
    warn "RAM: need $((need_ram/1024)) GiB, have only $((have_ram_mb/1024)) GiB - THIS LAYOUT DOES NOT FIT"; fail=1
  fi
  # vCPU over-subscription is a choice, not a fault - the lab runs 2:1 deliberately. Report it.
  if [ "$vc" -le "$have_threads" ]; then
    ok "vCPU: $vc assigned, $have_threads threads"
  else
    say "[--] vCPU: $vc assigned on $have_threads threads - $(( (vc*10+have_threads/2) / have_threads ))/10 : 1 over-subscription (deliberate in the lab)"
  fi
  # || true: df fails when the pool is not there, and under `set -e` an unguarded assignment
  # from a failing pipeline ENDS THE SCRIPT SILENTLY - which it did on 2026-09-20, skipping
  # every check after this line and still exiting 0. A missing pool must be reported, not fatal.
  local pool_avail; pool_avail="$(df -BG --output=avail "$POOL" 2>/dev/null | tail -1 | tr -dc 0-9 || true)"
  if [ -n "$pool_avail" ]; then
    # The ceiling is over-committed on purpose; what matters is that today's guests fit.
    if [ "$dk" -le "$pool_avail" ]; then
      ok "pool $POOL: ${pool_avail} GB free, ${dk} GB of ceilings - fits even unsparse"
    else
      warn "pool $POOL: ${pool_avail} GB free vs ${dk} GB of ceilings - sparse today, and it CAN fill. Watch it or grow the pool"
    fi
  else
    warn "cannot measure $POOL - is it mounted?"
  fi
  if [ "$dt" -gt 0 ]; then
    local dpool="${VM_POOL_DATA:-}"
    [ -n "$dpool" ] || { warn "guests here want ${dt} GB of data disk and VM_POOL_DATA is unset"; fail=1; }
  fi
  printf '\n'
  [ "$fail" -eq 0 ] || die "the plan does not hold on $me - fix the map or the hardware before composing"
  ok "plan holds on $me"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1; shift ;;
    --destroy)    DESTROY=1; shift ;;
    --spec)       PLAN_ARG=--spec; shift ;;
    -h|--help)    sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           die "unknown option $1" ;;
    *)            VM="$1"; shift ;;
  esac
done
[ -n "$VM" ] || { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }


[ -r "$ENCLAVE_DIR/enclave-addresses.env" ] || die "no enclave-addresses.env in $ENCLAVE_DIR"
[ -r "$ENCLAVE_DIR/vm-specs.env" ]          || die "no vm-specs.env in $ENCLAVE_DIR"
# shellcheck disable=SC1090
. "$ENCLAVE_DIR/enclave-addresses.env"
# shellcheck disable=SC1090
. "$ENCLAVE_DIR/vm-specs.env"

# `plan` answers "what runs where, and does it fit" and composes nothing. It needs the two
# env files above and nothing else - no root, no libvirt - so it runs before any of the
# machine-specific checks below, and on a machine that holds no guests at all.
if [ "$VM" = plan ]; then POOL="${VM_POOL:-}"; cmd_plan "$PLAN_ARG"; exit 0; fi

# svc-mgmt-01 -> SVC_MGMT_01
KEY_NAME="$(echo "$VM" | tr 'a-z-' 'A-Z_')"
ADDRESS="${!KEY_NAME:-}"
SPEC_VAR="VM_$KEY_NAME"; SPEC="${!SPEC_VAR:-}"
[ -n "$ADDRESS" ] || die "$VM has no address. Add $KEY_NAME to enclave-addresses.env."
[ -n "$SPEC" ]    || die "$VM has no spec. Add $SPEC_VAR to vm-specs.env."
# vcpus:ram_mb:disk_gb[:data_gb] - the 4th field is OPTIONAL and reads as empty when absent,
# so every spec written before 2026-09-16 behaves exactly as it did.
IFS=: read -r VCPUS RAM_MB DISK_GB DATA_GB <<< "$SPEC"

POOL="${VM_POOL:?}"; BRIDGE="${VM_BRIDGE:?}"; DOMAIN="${ENCLAVE_DOMAIN:?}"
DISK="$POOL/$VM.qcow2"
SEED="$POOL/seed/$VM-seed.iso"

# A SECOND disk, on a DIFFERENT PHYSICAL DEVICE. Only pg-01..03 use it today: their data and
# WAL belong on the 1 TB M.2, not on the 256 GB M.2 that already carries the host OS and
# k8s-cp-0N - two databases fsyncing through one device is how you get spurious leader
# elections in both etcd clusters at once. VM_POOL_DATA is where; unset means no data disk,
# and asking for one without it is refused rather than silently landed on the OS device.
DATA_POOL="${VM_POOL_DATA:-}"
DATA_DISK=""
if [ -n "${DATA_GB:-}" ] && [ -n "$DATA_POOL" ]; then DATA_DISK="$DATA_POOL/$VM-data.qcow2"; fi

# ---- destroy ----------------------------------------------------------------------------
if [ "$DESTROY" -eq 1 ]; then
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  say "this DESTROYS $VM and $DISK"
  run virsh destroy "$VM" 2>/dev/null || true
  # --nvram also deletes the guest's UEFI variable store; undefine refuses a UEFI guest
  # without it (or --keep-nvram).
  run virsh undefine "$VM" --nvram 2>/dev/null || true
  run rm -f "$DISK" "$SEED" ${DATA_DISK:+"$DATA_DISK"}
  ok "$VM removed"; exit 0
fi

# ---- refuse to compose a guest anywhere but its declared home ----------------------------
# CHECKED BEFORE THE ROOT CHECK, DELIBERATELY: being on the wrong machine needs no
# privilege to discover, and an operator on the wrong host should be told THAT rather
# than being asked for a sudo password first.
# backlog 2.7. THIS WAS A WARNING, AND IT NAMED host-4 UNCONDITIONALLY - which is exactly how
# every service VM came to live on one machine (red flag 1.2). A warning refuses nothing, and
# the composer had no idea where a guest was supposed to live. The placement map in
# vm-specs.env is now the authority, and putting a guest somewhere else is an EDIT TO THE MAP,
# reviewable in git, rather than a decision made at a keyboard at 2am.
PLACE="$(vm_place "$VM")"
[ -n "$PLACE" ] || die "$VM has no declared home.
       Add PLACE_$KEY_NAME='host-N' to vm-specs.env - nothing is composed without one.
       Check the layout first:  $0 plan --spec"
PLACE_ADDR_VAR="$(echo "$PLACE" | tr 'a-z-' 'A-Z_')"; PLACE_ADDR="${!PLACE_ADDR_VAR:-}"
ME="$(hostname -s)"
if [ "$DRY" -eq 0 ] && [ "$ME" != "$PLACE" ] \
   && ! { [ -n "$PLACE_ADDR" ] && ip -br addr | grep -qw "${PLACE_ADDR%%/*}"; }; then
  die "$VM belongs on $PLACE (VM_PROFILE=$VM_PROFILE) and this machine is $ME.
       Either run it on $PLACE, or change PLACE_$KEY_NAME in vm-specs.env and say why."
fi
[ "$DRY" -eq 1 ] || ok "placement: $VM -> $PLACE (this machine)"

[ "$DRY" -eq 1 ] || [ "$(id -u)" -eq 0 ] || die "run with sudo"


# These describe the target host, so they are checked for a real run only. A dry run must be
# usable anywhere - reviewing the rendered cloud-init is exactly what it is for.
if [ "$DRY" -eq 0 ]; then
  virsh version >/dev/null 2>&1 || die "cannot reach libvirt - run 03-host-services.sh libvirt"
  if virsh dominfo "$VM" >/dev/null 2>&1; then
    die "$VM already exists. Remove it first:  sudo $0 $VM --destroy"
  fi
  mountpoint -q "$POOL" || warn "$POOL is not its own volume - VM disks will fill the root fs"
fi

# ---- tools -------------------------------------------------------------------------------
MISSING=""
for c in cloud-localds qemu-img virt-install; do command -v "$c" >/dev/null || MISSING="$MISSING $c"; done
if [ -n "$MISSING" ] && [ "$DRY" -eq 0 ]; then
  say "installing tooling for:$MISSING"
  run apt-get install -y --no-install-recommends cloud-image-utils qemu-utils \
    || die "could not install cloud-image-utils / qemu-utils - is apt pointed at the mirror?"
fi
[ -r "$VM_BASE_IMAGE" ] || [ "$DRY" -eq 1 ] || die "no base image at $VM_BASE_IMAGE
       Copy it from stage-01:
         scp encadmin@10.0.20.160:/srv/bundle-staging/media/ubuntu-24.04-minimal-cloudimg-amd64.img \\
             $VM_BASE_IMAGE"

say "vm      : $VM  ($ADDRESS)"
say "spec    : ${VCPUS} vCPU, ${RAM_MB} MB, ${DISK_GB} GB sparse"
say "bridge  : $BRIDGE"

# ---- disk --------------------------------------------------------------------------------
# 0711: qemu can open a seed by its path, other users cannot list the directory - every
# seed carries the admin password hash and the authorized keys.
run install -d -m 0711 "$POOL/seed"
# Log the serial console to a file AND keep an interactive pty. A VM with no default route
# that fails to bring up networking is invisible: no ssh, and the log is the only evidence of
# what went wrong once nobody is watching.
#
# THIS WAS HALF-BROKEN UNTIL 2026-09-11 AND NOBODY NOTICED FOR A WEEK.
#   --console pty,target_type=serial   +   --serial file,path=...
# looks like "both", and is not. In libvirt a <console> with target type='serial' is a VIEW of
# the first serial port, not a second device - they share alias serial0 - so the two requests
# were reconciled and the FILE definition won. Every VM came out with:
#     <serial type='file'> ... <console type='file'>
# and NO pty at all. `virsh console` then fails with
#     error: internal error: character device serial0 is not using a PTY
# meaning no VM in the enclave had an interactive console: nothing could type a GRUB password,
# drive a rescue shell, or answer an fsck prompt. The recovery route the runbook advertised
# did not exist. See runbook 6.3j.
#
# The fix is ONE device that does both - a pty with a <log> child, supported by libvirt >=1.3.3
# (host has 10.0.0) and exposed by virt-install 4.1.0 as log.file / log.append.
LOGDIR="$POOL/console"
run install -d -m 0755 "$LOGDIR"
# The log is written by qemu, which recreates it under its own umask - so pre-creating it
# 0644 does NOT survive. It has to be chmod'd again AFTER virt-install has started the
# domain. A diagnostic nobody can read without an interactive sudo is only half a fix.
# A full copy, NOT a backing-file overlay. An overlay would save a few hundred MB per VM and
# tie all ten to one file: delete or corrupt the base and every VM dies at once, and the base
# can never be retired. A converted copy costs ~600 MB each - 6 GB across the fleet, against
# 1.9 TB - and each VM is then independent. Cheap insurance.
run qemu-img convert -f qcow2 -O qcow2 "$VM_BASE_IMAGE" "$DISK"
# Grows the VIRTUAL size only (still sparse); cloud-init's growpart extends the root
# filesystem into it on first boot.
run qemu-img resize "$DISK" "${DISK_GB}G"
ok "disk    : $DISK (independent copy, sparse, grown to ${DISK_GB}G)"

if [ -n "${DATA_GB:-}" ]; then
  [ -n "$DATA_POOL" ] || die "$VM asks for a ${DATA_GB}G data disk but VM_POOL_DATA is unset.
      A data disk on the OS device is not a data disk - the point of asking for one is that it
      is a different spindle. Set VM_POOL_DATA in vm-specs.env to a path on the data device."
  run install -d -m 0711 "$DATA_POOL"
  # CREATE, not convert - a data disk is blank, there is no base image for it.
  [ -e "$DATA_DISK" ] || run qemu-img create -f qcow2 -o preallocation=metadata \
      "$DATA_DISK" "${DATA_GB}G"
  ok "data    : $DATA_DISK (${DATA_GB}G, sparse, metadata preallocated)"
  # IT LANDS AT vdc, BEHIND THE READ-ONLY SEED - AND THAT IS NOT STABLE. The seed disk is
  # only needed for the first boot; detach it later and the data disk moves vdc -> vdb.
  # So MOUNT IT BY UUID OR LABEL, NEVER BY /dev/vdX. An fstab entry naming vdc is a machine
  # that boots fine today and comes up with no database directory after the seed is removed.
  say "        mount it by UUID or LABEL - it is vdc now and would become vdb if the"
  say "        seed disk is ever detached. Never put /dev/vdX in its fstab."
fi

# ---- cloud-init --------------------------------------------------------------------------
# The hosts block comes from apply-addresses.sh so there is exactly one renderer. A VM that
# writes its own copy is a second source of truth waiting to disagree.
HOSTS_BLOCK="$("$ENCLAVE_DIR/apply-addresses.sh" render | sed 's/^/      /')"
# THE RESOLVER, FROM THE SAME RENDERER (backlog 6b.1e). Without it every VM is born with no
# enclave DNS - hosts-file names work, *.apps and CoreDNS forwarding do not. Included ONLY if
# the DNS server answers now: a resolver pointed at a dead server adds a timeout to every
# lookup the hosts file does not cover, which is worse than no resolver.
RESOLVER_WF=""; RESOLVER_RUN=""
if DNS_ADDR="$("$ENCLAVE_DIR/apply-addresses.sh" resolver-check 2>/dev/null)"; then
  RESOLVER_WF="  - path: /etc/systemd/resolved.conf.d/10-enclave-dns.conf
    permissions: '0644'
    content: |
$("$ENCLAVE_DIR/apply-addresses.sh" resolver | sed 's/^/      /')"
  RESOLVER_RUN="  - [ systemctl, restart, systemd-resolved ]"
  ok "resolver  : enclave DNS $DNS_ADDR answers - the VM will use it from first boot"
else
  warn "resolver  : enclave DNS is NOT answering - this VM gets /etc/hosts only."
  warn "            Afterwards, ON the VM: sudo ./apply-addresses.sh resolver-install"
fi
# Shared operator tmux config, same file the bare-metal hosts get.
TMUX_CONF=""
[ -r "$ENCLAVE_DIR/tmux.conf" ] && TMUX_CONF="$(sed 's/^/      /' "$ENCLAVE_DIR/tmux.conf")"
# The enclave root CA, so a VM trusts the PKI from its first boot rather than needing a visit.
# A machine that does not trust the root cannot reach an HTTPS mirror - and the failure looks
# like a certificate problem on the SERVER, which is where people look first.
# EVERY anchor in trust-anchors/, not just this CA's root. A site running DoD PKI drops its
# roots in there and composed VMs pick them up with no change here - which is the whole point
# of that directory being a directory.
# ---- the admin password -------------------------------------------------------------------
# EVERY VM GETS ONE, and it is not optional.
#
# The composer used to create the user with `sudo: ALL=(ALL) NOPASSWD:ALL` and NO password at
# all. That works right up until the DISA STIG is applied: usg removes NOPASSWD (correctly -
# STIG requires sudo to authenticate), and sudo then asks for a password that was never set.
# There is no number of attempts that succeeds. On svc-harbor-01 on 2026-09-08 that locked
# the only sudo-capable account out of root on a headless VM, recoverable only by editing the
# disk offline from the hypervisor.
#
# Had it been found later it would have done that to all six Kubernetes nodes at once.
#
# NOPASSWD is KEPT as well, deliberately: it is convenient before hardening, and STIG removes
# it afterwards - at which point the password below is what keeps the machine usable.
#
# A HASH goes in the user-data, never the password. cloud-init's user-data sits on the seed
# ISO and in /var/lib/cloud on the guest, both readable.
#
# WHERE THE HASH COMES FROM (3.32): VM_ADMIN_PASSWORD_HASH in the environment > the same key in
# the site credentials file (/etc/enclave/credentials.env, root 600 - see credentials.sh) >
# asked for here. One hash for every guest built from that file.
VM_ADMIN_HASH="${VM_ADMIN_PASSWORD_HASH:-}"; VM_ADMIN_SRC="VM_ADMIN_PASSWORD_HASH (environment)"
if [ -z "$VM_ADMIN_HASH" ] && [ "$DRY" -eq 0 ]; then
  # shellcheck source=../enclave/credentials.sh
  . "$ENCLAVE_DIR/credentials.sh"
  cred_require_safe
  VM_ADMIN_HASH="$(cred_get VM_ADMIN_PASSWORD_HASH)"; VM_ADMIN_SRC="$ENCLAVE_CREDENTIALS"
fi
if [ -n "$VM_ADMIN_HASH" ]; then
  # CHECK THE SHAPE: a truncated paste would set a password that matches nothing, and the
  # lock-out above would only show up after hardening.
  [[ "$VM_ADMIN_HASH" =~ ^\$6\$[^\$]+\$[./A-Za-z0-9]+$ ]] \
    || die "the VM admin hash from $VM_ADMIN_SRC is not SHA-512 crypt (\$6\$...) - nothing created"
  ok "VM admin password: hash from $VM_ADMIN_SRC - no prompt"
elif [ "$DRY" -eq 0 ]; then
  if [ -t 0 ]; then
    printf '  no VM_ADMIN_PASSWORD_HASH set - enter a password for %s on %s\n' "${VM_USER:-encadmin}" "$VM"
    read -rsp '  password: ' _p1; echo
    read -rsp '  again:    ' _p2; echo
    [ -n "$_p1" ] || die "refusing to create a VM with an empty password - STIG will make it unusable"
    [ "$_p1" = "$_p2" ] || die "the two entries do not match"
    # -stdin keeps it off the command line and out of ps.
    VM_ADMIN_HASH=$(printf '%s' "$_p1" | openssl passwd -6 -stdin) || die "hashing failed"
    unset _p1 _p2
  else
    die "no VM_ADMIN_PASSWORD_HASH and no terminal to prompt on.
      Unattended:     VM_ADMIN_PASSWORD_HASH in $ENCLAVE_CREDENTIALS (make-credentials.sh)
      Or for one run: VM_ADMIN_PASSWORD_HASH='<hash>' sudo -E ./03-compose-vm.sh $VM"
  fi
fi

ANCHOR_DIR="$ENCLAVE_DIR/trust-anchors"
ROOT_CA=""; ANCHOR_COUNT=0
if [ -d "$ANCHOR_DIR" ]; then
  for _a in "$ANCHOR_DIR"/*.crt; do
    [ -r "$_a" ] || continue
    # Each anchor is its own list entry: "    - |" then the PEM indented under it.
    ROOT_CA="${ROOT_CA}    - |
$(sed 's/^/      /' "$_a")
"
    ANCHOR_COUNT=$((ANCHOR_COUNT + 1))
  done
fi
# Delivered through cloud-init's `ca_certs` module, NOT through write_files plus a runcmd.
# The module order on a composed VM, read off svc-mgmt-01 rather than remembered:
#
#   cloud_init_modules   ... write_files, ca_certs, ...
#   cloud_config_modules ... apt_configure, runcmd, ...        <- runcmd only WRITES the script
#   cloud_final_modules  ... package_update_upgrade_install, ..., scripts_user
#                                                              ^ this is where runcmd RUNS
#
# So packages install before runcmd ever executes. `update-ca-certificates` in runcmd is too
# late by two module groups: with an https mirror the very first apt run happens against an
# untrusted root and fails, on a VM with no other route to a package. ca_certs runs in the
# first group, before apt_configure has even read the sources.
#
# An empty block is omitted entirely - `ca_certs: trusted: [ ]` with no cert is a parse error
# waiting for the one build where root-ca.crt has not been staged yet.
CA_CERTS_BLOCK=""
if [ "$ANCHOR_COUNT" -gt 0 ]; then
  CA_CERTS_BLOCK="ca_certs:
  trusted:
${ROOT_CA%$'\n'}"
fi
# Find the keys under sudo, which is how this always runs. $HOME is /root there, so the
# operator's own authorized_keys is invisible unless SUDO_USER is resolved back to a home
# directory - and the failure looks like "you have no keys" rather than "I looked in the
# wrong place".
SSH_KEY_SEARCH="${VM_SSH_KEYS:-}"
if [ -z "$SSH_KEY_SEARCH" ]; then
  if [ -n "${SUDO_USER:-}" ]; then
    SUDO_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [ -n "$SUDO_HOME" ] && SSH_KEY_SEARCH="$SUDO_HOME/.ssh/authorized_keys"
  fi
  SSH_KEY_SEARCH="$SSH_KEY_SEARCH $HOME/.ssh/authorized_keys /root/.ssh/authorized_keys"
fi

SSH_KEYS_YAML=""
for k in $SSH_KEY_SEARCH; do
  [ -r "$k" ] || continue
  while IFS= read -r line; do
    case "$line" in ssh-*|ecdsa-*) SSH_KEYS_YAML="$SSH_KEYS_YAML      - \"$line\""$'\n' ;; esac
  done < "$k"
done
[ -n "$SSH_KEYS_YAML" ] || die "no ssh public keys found. Looked in:
$(for k in $SSH_KEY_SEARCH; do printf '         %s%s\n' "$k" "$([ -r "$k" ] && echo ' (readable, but no ssh-* lines)' || echo ' (not readable)')"; done)
       Set VM_SSH_KEYS to a file containing them. Without a key the VM has no default
       route AND no way in - it would boot and be unreachable."

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# A fresh instance-id on every compose, so cloud-init treats a recomposed guest as a first
# boot and runs the whole user-data again.
cat > "$TMP/meta-data" <<EOF
instance-id: $VM-$(date +%s)
local-hostname: $VM
EOF

# No gateway4 and no nameservers: this VM is air-gapped exactly like its host.
# Match on en* rather than naming the interface. A virtio NIC comes up as enp1s0 on some
# machine types and ens3 on others, and guessing wrong produces a VM with no address AND no
# default route - unreachable, recoverable only from the console. Same idiom the host
# autoinstall uses for the same reason.
cat > "$TMP/network-config" <<EOF
version: 2
ethernets:
  primary:
    match:
      name: "en*"
    dhcp4: false
    dhcp6: false
    addresses: [$ADDRESS/24]
EOF

cat > "$TMP/user-data" <<EOF
#cloud-config
hostname: $VM
fqdn: $VM.$DOMAIN
prefer_fqdn_over_hostname: false
manage_etc_hosts: false

users:
  - name: ${VM_USER:-encadmin}
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: $VM_ADMIN_HASH
    ssh_authorized_keys:
$SSH_KEYS_YAML
# preserve_sources_list: true is LOAD-BEARING. With the 'primary'/'security' form, cloud-init
# generates ubuntu.sources from ITS OWN template - default suites and components - and does so
# AFTER write_files, silently overwriting the file below. On svc-mgmt-01 (2026-09-03) that
# produced:
#     Suites: noble noble-updates noble-backports
#     Components: main universe restricted multiverse
# against a mirror carrying only main+universe and no backports, so apt-get update 404'd on
# every one of them. cloud-init then fell back to trying 'snap install' for each package -
# 30 seconds apiece against a store it cannot reach - and sat in 'running' for minutes.
# Preserving the list and writing the file ourselves is the only way to control components.
$CA_CERTS_BLOCK

apt:
  preserve_sources_list: true

write_files:
  - path: /etc/apt/sources.list.d/ubuntu.sources
    permissions: '0644'
    content: |
      # Enclave mirror. No default route on this VM; reachable on the local subnet only.
      Types: deb
      URIs: $VM_MIRROR_URL
      Suites: $VM_MIRROR_SUITES
      Components: $VM_MIRROR_COMPONENTS
      Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
  - path: /etc/tmux.conf
    permissions: '0644'
    content: |
$TMUX_CONF
  - path: /etc/hosts
    permissions: '0644'
    content: |
      127.0.0.1       localhost
      127.0.1.1       $VM $VM.$DOMAIN
      ::1             localhost ip6-localhost ip6-loopback
$HOSTS_BLOCK
$RESOLVER_WF

package_update: true
packages: [$(echo "${VM_EXTRA_PACKAGES:-}" | tr ' ' '\n' | sed '/^$/d' | paste -sd, -)]

runcmd:
  - [ systemctl, enable, --now, ssh ]
$RESOLVER_RUN
  - [ sh, -c, "ip route | grep -q '^default' && echo 'WARNING: this VM has a default route' >> /etc/enclave-build-info || echo 'gateway=none-airgapped-no-default-route' >> /etc/enclave-build-info" ]
  - [ sh, -c, "echo \"composed=\$(date -Is) by 03-compose-vm.sh\" >> /etc/enclave-build-info" ]

final_message: "$VM ready after \$UPTIME seconds"
EOF

if [ "$DRY" -eq 1 ]; then
  say ""; say "--- user-data that would be written ---"; sed 's/^/  /' "$TMP/user-data"
  say ""; say "--- network-config ---"; sed 's/^/  /' "$TMP/network-config"
  exit 0
fi

# See vm-specs.env for why UEFI is the default - SeaBIOS failures are invisible with
# --graphics none, because SeaBIOS only writes to VGA.
# '--boot uefi' is NOT plain UEFI - it selects the Microsoft-keys-enrolled Secure Boot
# firmware, under which Ubuntu's GRUB stopped with "prohibited by secure boot policy" and
# cloud-init never ran. Ask for the features explicitly instead of taking the default.
FIRMWARE_ARGS=()
case "${VM_FIRMWARE:-uefi}" in
  uefi)
    if [ "${VM_SECURE_BOOT:-false}" = "true" ]; then
      FIRMWARE_ARGS=(--boot uefi)
    else
      FIRMWARE_ARGS=(--boot "firmware=efi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=no")
    fi ;;
  bios) FIRMWARE_ARGS=() ;;
  *)    die "VM_FIRMWARE must be 'uefi' or 'bios', not '${VM_FIRMWARE}'" ;;
esac

# The NoCloud seed image (volume label cidata): user-data, meta-data and network-config.
cloud-localds -N "$TMP/network-config" "$SEED" "$TMP/user-data" "$TMP/meta-data"
ok "seed    : $SEED"

# ---- define and start --------------------------------------------------------------------
# THE SEED GOES ON VIRTIO, NOT AS A SATA CDROM. Found on svc-mgmt-01 2026-09-03:
# virt-install's default for device=cdrom is the SATA bus, and an Ubuntu cloud image ships a
# TRIMMED INITRAMFS carrying only virtio drivers - no AHCI. The guest therefore enumerated
# only vda and never saw the seed at all:
#
#     virtio_blk virtio2: [vda] 209715200 512-byte logical blocks
#     vda: vda1 vda14 vda15 vda16          <- no sr0, no sda, no ata
#
# ds-identify then found no datasource and systemd SKIPPED every cloud-init unit, which
# produces no error and no output - the VM boots to a stock 'ubuntu' login with no address,
# looking alive and being useless. NoCloud matches on the filesystem label, not on the device
# being a cdrom, so a read-only virtio disk works and is visible to the trimmed initramfs.
# Data disk: cache=none so a database fsync reaches the device rather than the host page
# cache; discard=unmap so TRIM inside the guest returns space to the sparse qcow2.
DATA_DISK_ARGS=()
if [ -n "$DATA_DISK" ]; then
  DATA_DISK_ARGS=(--disk "path=$DATA_DISK,format=qcow2,bus=virtio,cache=none,io=native,discard=unmap")
fi

# host-passthrough: the guest sees the host CPU's real model and flags, not a generic one.
virt-install \
  --name "$VM" \
  --memory "$RAM_MB" --vcpus "$VCPUS" \
  --cpu host-passthrough \
  --os-variant "${VM_OSVARIANT:-ubuntu24.04}" \
  "${FIRMWARE_ARGS[@]}" \
  --disk "path=$DISK,format=qcow2,bus=virtio" \
  --disk "path=$SEED,device=disk,bus=virtio,format=raw,readonly=on" \
  "${DATA_DISK_ARGS[@]}" \
  --network "bridge=$BRIDGE,model=virtio" \
  --graphics none \
  --console pty,target_type=serial \
  --serial "pty,log.file=$LOGDIR/$VM-console.log,log.append=on" \
  --import --noautoconsole
ok "defined and started"

# The guest starts with its host. After host-4's reboot on 2026-09-22 all four guests came
# back with nobody at a console (backlog 1.1).
virsh autostart "$VM" >/dev/null
ok "autostart enabled"

# Now that qemu has created it, make the console log readable over ssh.
chmod 0644 "$LOGDIR/$VM-console.log" 2>/dev/null \
  && ok "console log readable: $LOGDIR/$VM-console.log" \
  || warn "could not chmod the console log - it will need sudo to read"

# PROVE THE PTY EXISTS. The whole point of the change above is an interactive console, and the
# failure mode is silent - the VM runs perfectly and you find out only when you need it most.
if virsh dumpxml "$VM" 2>/dev/null | grep -q "<serial type='pty'>"; then
  ok "interactive console present - virsh console $VM will work"
else
  warn "NO PTY SERIAL - 'virsh console $VM' will fail with 'not using a PTY'."
  warn "  This VM has no interactive console. Offline disk editing (vm-rescue.sh) is the only"
  warn "  way back if it will not boot. See runbook 6.3j."
fi

say ""
say "cloud-init takes a minute or two. Watch it:"
say "    sudo virsh console $VM        (escape is Ctrl-])"
say "Or read the console log, which needs no interactive session:"
say "    sudo tail -f $LOGDIR/$VM-console.log"
say "Then, from anywhere on the subnet:"
say "    ssh ${VM_USER:-encadmin}@$ADDRESS 'cat /etc/enclave-build-info'"
