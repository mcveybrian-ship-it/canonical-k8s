#!/usr/bin/env bash
# =========================================================================================
# 03-host-services.sh - prepare a bare-metal host to run enclave service VMs.
#
#     MACHINE: runs ON the host being prepared (host-4 first). Never on stage-01.
#
# Everything here is idempotent: run a subcommand twice and the second run reports
# "already done" rather than failing or duplicating. That matters because this procedure
# has to be repeatable by someone who is not the person who wrote it.
#
#     ./03-host-services.sh hosts      /etc/hosts from the address file
#     ./03-host-services.sh trustca    install the enclave root CA  <-- BEFORE apt
#     ./03-host-services.sh apt        point apt at the mirror
#     ./03-host-services.sh libvirt    install the virtualisation stack
#     ./03-host-services.sh datavg     create LVs on vg-data and mount them
#     ./03-host-services.sh bridge     replace the NIC with a bridge   <-- can cut you off
#     ./03-host-services.sh pool       define the libvirt storage pool
#     ./03-host-services.sh tmux       tmux + the shared /etc/tmux.conf
#     ./03-host-services.sh keyonly    disable password SSH  <-- do this LAST
#     ./03-host-services.sh verify     prove all of the above, change nothing
#     ./03-host-services.sh all        hosts, trustca, apt, libvirt, datavg, pool, tmux, verify
#                                      (NOT bridge)
#
# "all" deliberately excludes "bridge". Every other step is reversible from an ssh session;
# the bridge step is the one that can leave an air-gapped host needing a physical console.
# =========================================================================================
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS="${PARAMS:-$SELF/03-host-services/services-params.env}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
skip() { printf '  [--] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run this with sudo: sudo $0 $*"; }

# -----------------------------------------------------------------------------------------
# Params. Validate quoting BEFORE sourcing - an unbalanced quote in a params file swallows
# the rest of it and produces an error that points at the wrong line. This cost an hour in
# step 02; see docs/02-host-install.md.
# -----------------------------------------------------------------------------------------
# Same guard as step 02, for the same reason: an unbalanced quote swallows the rest of the
# file and the error points at the wrong line. Extended here to ignore a trailing comment,
# because "libvirt's NAT" in a comment is not an unbalanced value.
_paramcheck() {
  local f="$1" n=0 bad=0 l body q i c inq
  while IFS= read -r l; do
    n=$((n+1))
    case "$l" in \#*|"") continue ;; esac
    body=""; inq=0
    for (( i=0; i<${#l}; i++ )); do
      c="${l:i:1}"
      [ "$c" = "'" ] && inq=$((1-inq))
      [ "$c" = "#" ] && [ "$inq" -eq 0 ] && break
      body+="$c"
    done
    q="${body//[^\']/}"
    if (( ${#q} % 2 )); then
      echo "  line $n: unbalanced single quote -> ${l%%=*}=..." >&2
      bad=1
    fi
  done < "$f"
  return $bad
}

load_params() {
  [ -r "$PARAMS" ] || die "no params file at $PARAMS
       cp $SELF/03-host-services/services-params.env.example $PARAMS"
  _paramcheck "$PARAMS" || die "$PARAMS has quoting errors - see above. Nothing was done."
  # shellcheck disable=SC1090
  . "$PARAMS"
  : "${MIRROR_URL:?}" "${MIRROR_SUITES:?}" "${MIRROR_COMPONENTS:?}" "${MIRROR_KEYRING:?}"

  # CA BEFORE APT. An https mirror is unreachable until the enclave root is in the trust
  # store, and the failure reads as a certificate problem on the SERVER - which is where
  # people look first, and the server is fine. `all` used to run apt first and trustca
  # sixth, which worked only for as long as the mirror was plaintext.
  #
  # Guarded here rather than only in `all` so that running `./03-host-services.sh apt`
  # on its own is also correct. cmd_trustca is idempotent and says so when it no-ops.
  case "$MIRROR_URL" in
    https://*)
      say "mirror is https - ensuring the enclave root is trusted first"
      cmd_trustca
      ;;
  esac

  # A mirror named rather than numbered needs /etc/hosts populated. Checking here turns
  # "apt-get update failed" into a sentence that says which name and how to fix it.
  MIRROR_HOST="${MIRROR_URL#*://}"; MIRROR_HOST="${MIRROR_HOST%%/*}"; MIRROR_HOST="${MIRROR_HOST%%:*}"
  case "$MIRROR_HOST" in
    *[a-zA-Z]*)
      getent hosts "$MIRROR_HOST" >/dev/null 2>&1 \
        || die "this machine cannot resolve '$MIRROR_HOST', which MIRROR_URL names.
      Populate /etc/hosts from the address file first:
        sudo ./03-host-services.sh hosts"
      ok "resolves $MIRROR_HOST"
      ;;
  esac
  : "${BRIDGE_NAME:?}" "${BRIDGE_NIC:?}" "${BRIDGE_ADDRESS:?}"
  : "${DATA_VG:?}" "${DATA_LVS:?}" "${DATA_FSTYPE:?}"
  : "${POOL_NAME:?}" "${POOL_PATH:?}"

  # ---------------------------------------------------------------------------------------
  # Refuse to run on a machine these params do not describe.
  #
  # Added 2026-09-02 after step B was pasted into a stage-01 window by mistake. That one was
  # harmless - it copies a file - but it left a params file behind, and a params file is the
  # only thing standing between "wrong window" and "sudo ./03-host-services.sh apt", which
  # would repoint the machine that BUILDS the mirror at the mirror it builds.
  #
  # BRIDGE_ADDRESS is the host's own address, so it identifies the machine without hardcoding
  # a hostname. Checked across every interface, because after the bridge step the address
  # lives on br0 rather than on the NIC.
  # ---------------------------------------------------------------------------------------
  if ! ip -br addr | grep -qw "${BRIDGE_ADDRESS%%/*}"; then
    die "these params describe $BRIDGE_ADDRESS, but $(hostname) has:
       $(ip -br addr | grep -v '^lo' | awk '{printf "%s %s  ", $1, $3}')
       Wrong machine. Nothing was done."
  fi

  case "$MIRROR_COMPONENTS" in
    *restricted*|*multiverse*)
      die "MIRROR_COMPONENTS names restricted/multiverse, which were not mirrored.
       apt-get update WILL fail. Mirrored components: main universe" ;;
  esac
}

# =========================================================================================
cmd_apt() {
  need_root apt; load_params
  local f=/etc/apt/sources.list.d/ubuntu.sources
  local new; new=$(mktemp)
  {
    echo "# Enclave apt mirror. Written by 03-host-services.sh on $(date -Is)."
    echo "# The host has no default route; this URL is reachable on the local subnet only."
    echo "Types: deb"
    echo "URIs: $MIRROR_URL"
    echo "Suites: $MIRROR_SUITES"
    echo "Components: $MIRROR_COMPONENTS"
    echo "Signed-By: $MIRROR_KEYRING"
  } > "$new"

  if [ -f "$f" ] && diff -q <(grep -v '^#' "$f") <(grep -v '^#' "$new") >/dev/null 2>&1; then
    rm -f "$new"; skip "apt already points at $MIRROR_URL"
  else
    [ -f "$f" ] && [ ! -f "$f.pre-mirror" ] && cp "$f" "$f.pre-mirror" && say "saved $f.pre-mirror"
    install -m 0644 "$new" "$f"; rm -f "$new"
    ok "wrote $f"
  fi

  # apt only reads *.list and *.sources. Anything else in that directory is inert - but a
  # file named *.sources.orig becomes LIVE the moment someone renames it, so say so.
  local stray
  stray=$(find /etc/apt/sources.list.d -maxdepth 1 -type f \
            ! -name '*.list' ! -name '*.sources' -printf '%f ' 2>/dev/null || true)
  [ -n "$stray" ] && say "inert backups present (apt ignores these): $stray"

  say "apt-get update ..."
  apt-get update -qq || die "apt-get update failed against $MIRROR_URL"
  ok "apt-get update succeeded, signatures verified"
}

# =========================================================================================
cmd_libvirt() {
  need_root libvirt; load_params
  local pkgs="qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst ovmf"
  local missing=""
  for p in $pkgs; do
    dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
  done
  if [ -z "$missing" ]; then
    skip "libvirt stack already installed"
  else
    say "installing:$missing"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $missing
    ok "installed"
  fi

  systemctl enable --now libvirtd >/dev/null 2>&1 || true
  [ -c /dev/kvm ] || die "/dev/kvm missing - check virtualisation is enabled in firmware"

  # Group membership does not apply to sessions that already exist.
  local u="${SUDO_USER:-}"
  if [ -n "$u" ]; then
    if id -nG "$u" | grep -qw libvirt && id -nG "$u" | grep -qw kvm; then
      skip "$u already in libvirt and kvm"
    else
      usermod -aG libvirt,kvm "$u"
      warn "$u added to libvirt,kvm - LOG OUT AND BACK IN before virsh works without sudo"
    fi
  fi

  if [ "${DISABLE_DEFAULT_NAT:-true}" = "true" ]; then
    if virsh -c qemu:///system net-info default >/dev/null 2>&1; then
      virsh -c qemu:///system net-destroy default >/dev/null 2>&1 || true
      virsh -c qemu:///system net-autostart default --disable >/dev/null 2>&1 || true
      ok "libvirt 'default' NAT network stopped and autostart disabled"
      say "    VMs go on $BRIDGE_NAME instead - 192.168.122.0/24 is unreachable from"
      say "    host-1..3, and svc-repo-01 has to serve apt to all of them"
    fi
  fi
  ok "libvirt $(virsh --version 2>/dev/null) ready"
}

# =========================================================================================
cmd_datavg() {
  need_root datavg; load_params
  vgs "$DATA_VG" >/dev/null 2>&1 || die "volume group '$DATA_VG' does not exist.
       The step-02 autoinstall creates it on crypt-data. Check: sudo vgs"

  local free; free=$(vgs --noheadings -o vg_free --units g "$DATA_VG" | tr -d ' g')
  say "$DATA_VG has ${free}G free"

  local spec name size mnt opts
  for spec in $DATA_LVS; do
    IFS=: read -r name size mnt <<< "$spec"
    [ -n "$name" ] && [ -n "$size" ] && [ -n "$mnt" ] \
      || die "malformed DATA_LVS entry '$spec' - want name:size:mountpoint"

    if lvs "$DATA_VG/$name" >/dev/null 2>&1; then
      skip "LV $DATA_VG/$name exists"
    else
      # A size ending in % is an extent count (lvcreate -l), anything else is bytes (-L).
      # 100%FREE is the normal case here: one pool volume taking whatever vg-data has.
      case "$size" in
        *%*) say "lvcreate -n $name -l $size $DATA_VG"
             lvcreate -n "$name" -l "$size" "$DATA_VG" >/dev/null ;;
        *)   say "lvcreate -n $name -L $size $DATA_VG"
             lvcreate -n "$name" -L "$size" "$DATA_VG" >/dev/null ;;
      esac
      ok "created $DATA_VG/$name ($size)"
    fi

    local dev="/dev/$DATA_VG/$name"
    if blkid "$dev" >/dev/null 2>&1; then
      skip "$dev already has a filesystem"
    else
      "mkfs.$DATA_FSTYPE" -q "$dev"
      ok "mkfs.$DATA_FSTYPE $dev"
    fi

    case "$mnt" in
      /var/lib/libvirt/*) opts="${DATA_MOUNTOPTS_LIBVIRT:-defaults}" ;;
      *)                  opts="${DATA_MOUNTOPTS_DEFAULT:-defaults}" ;;
    esac

    mkdir -p "$mnt"
    local uuid; uuid=$(blkid -s UUID -o value "$dev")
    if grep -q "UUID=$uuid" /etc/fstab; then
      skip "fstab entry for $mnt exists"
    else
      cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d%H%M%S)"
      printf 'UUID=%s  %s  %s  %s  0 2\n' "$uuid" "$mnt" "$DATA_FSTYPE" "$opts" >> /etc/fstab
      ok "fstab += $mnt ($opts)"
      # Reload BEFORE mounting. systemd caches fstab, and mounting against the stale copy
      # prints a "your fstab has been modified" hint that makes a clean run look broken.
      systemctl daemon-reload
    fi
    mountpoint -q "$mnt" || mount "$mnt"
  done

  # Prove fstab is not booby-trapped. A bad fstab on a host with no default route and no
  # console is a trip to the rack.
  mount -a && ok "mount -a clean - fstab will not break the next boot"
}

# =========================================================================================
cmd_bridge() {
  need_root bridge; load_params
  local np=/etc/netplan/70-bridge.yaml

  ip -br link show "$BRIDGE_NIC" >/dev/null 2>&1 \
    || die "NIC '$BRIDGE_NIC' not found. Present: $(ip -br link | awk '{print $1}' | tr '\n' ' ')"

  if ip -br addr show "$BRIDGE_NAME" >/dev/null 2>&1; then
    skip "$BRIDGE_NAME already exists"; return 0
  fi

  # The address must currently be ON the NIC we are about to enslave. If it is not, the
  # params are describing a different machine and applying them would strand this one.
  local have; have=$(ip -br addr show "$BRIDGE_NIC" | awk '{print $3}')
  [ "$have" = "$BRIDGE_ADDRESS" ] \
    || die "BRIDGE_ADDRESS is $BRIDGE_ADDRESS but $BRIDGE_NIC currently has ${have:-nothing}.
       Refusing: these params do not describe this machine."

  # ---------------------------------------------------------------------------------------
  # Move aside any netplan file that already assigns this address.
  #
  # Found on host-4 2026-09-02. The step-02 autoinstall writes 50-cloud-init.yaml defining the
  # NIC as 'primary' with match name:"en*" - NOT as enp42s0. Netplan merges by that id, so
  # simply adding a bridge file produced TWO units matching the same NIC: one bridging it and
  # one still assigning the address to it. Which won depended on generated-filename order.
  #
  # 'addresses: []' in a later file does NOT clear it - netplan merges keys, it does not
  # replace them. Verified with netplan generate --root-dir. The old file has to go.
  # ---------------------------------------------------------------------------------------
  local bdir moved=0 f
  bdir="/root/netplan.pre-bridge-$(date +%Y%m%d%H%M%S)"
  for f in /etc/netplan/*.yaml; do
    [ -e "$f" ] || continue
    [ "$f" = "$np" ] && continue
    if grep -q "${BRIDGE_ADDRESS%%/*}" "$f" 2>/dev/null; then
      [ "$moved" -eq 0 ] && mkdir -p "$bdir"
      mv "$f" "$bdir/"
      warn "moved $f -> $bdir/ (it also assigns ${BRIDGE_ADDRESS%%/*})"
      moved=1
    fi
  done
  if [ "$moved" -eq 1 ]; then
    say "    netplan try reverts the RUNNING network but NOT /etc/netplan - a file you"
    say "    remove stays removed. To undo by hand:  sudo cp $bdir/* /etc/netplan/"
  fi

  local routes="" dns=""
  [ -n "${BRIDGE_GATEWAY:-}" ] && routes="
      routes:
        - to: default
          via: $BRIDGE_GATEWAY"
  [ -n "${BRIDGE_DNS:-}" ] && dns="
      nameservers:
        addresses: [$BRIDGE_DNS]"

  # NO 'parameters:' BLOCK, and that is deliberate. Found on host-4 2026-09-02:
  # netplan try REFUSES to run at all on a bridge carrying custom parameters -
  #     br0: reverting custom parameters for bridges and bonds is not supported
  # - and exits before applying anything, so the auto-revert safety net does not exist for
  # such a config. Confirmed in try_command.py is_revertable(): any bridge whose
  # _is_trivial_compound_itf is False is rejected, and setting stp/forward-delay is exactly
  # what makes it False.
  #
  # stp: false and forward-delay: 0 only restate the kernel's own defaults for a bridge, so
  # omitting them costs nothing and buys back a config that can auto-revert. If you ever DO
  # need custom bridge parameters, add them and apply with 'netplan apply' AT THE CONSOLE -
  # there is no safety net for that path.
  cat > "$np" <<YAML
# Bridge for enclave service VMs. Written by 03-host-services.sh on $(date -Is).
# No gateway by design: this host is air-gapped and reaches its own subnet only.
# No parameters: block - it would make netplan try refuse. See the script."
network:
  version: 2
  ethernets:
    $BRIDGE_NIC:
      dhcp4: false
      dhcp6: false
  bridges:
    $BRIDGE_NAME:
      interfaces: [$BRIDGE_NIC]
      dhcp4: false
      dhcp6: false
      addresses: [$BRIDGE_ADDRESS]$routes$dns
YAML
  chmod 600 "$np"
  ok "wrote $np"

  netplan generate || { rm -f "$np"; die "netplan generate failed - $np removed, nothing applied"; }
  ok "netplan generate clean"

  # Exactly one unit may carry the address. Two means the NIC is bridged AND addressed.
  local n; n=$(grep -l "Address=$BRIDGE_ADDRESS" /run/systemd/network/* 2>/dev/null | wc -l)
  [ "$n" -eq 1 ] || die "generated $n units carrying $BRIDGE_ADDRESS, expected exactly 1.
       Applying this would strand the host. Nothing was applied."
  ok "exactly one interface carries $BRIDGE_ADDRESS"

  # netplan try reverts by itself if nobody confirms. On the only NIC of an air-gapped host
  # that auto-revert is the difference between a retry and a drive to the rack.
  if [ -t 0 ] && [ -t 1 ]; then
    warn "applying with 'netplan try' - it AUTO-REVERTS in 120s unless you press ENTER."
    warn "if your ssh session dies, wait 2 minutes and reconnect on $BRIDGE_ADDRESS."
    netplan try --timeout 120 || { rm -f "$np"; die "reverted - $np removed"; }
    ok "bridge applied and confirmed"
  else
    rm -f "$np"
    die "no TTY. This step can strand the host, so it refuses to run unattended.
       Re-run it from an interactive session (or the physical console)."
  fi
}

# =========================================================================================
cmd_pool() {
  need_root pool; load_params
  mkdir -p "$POOL_PATH"
  if virsh -c qemu:///system pool-info "$POOL_NAME" >/dev/null 2>&1; then
    skip "storage pool '$POOL_NAME' exists"
  else
    virsh -c qemu:///system pool-define-as "$POOL_NAME" dir --target "$POOL_PATH" >/dev/null
    virsh -c qemu:///system pool-build "$POOL_NAME" >/dev/null 2>&1 || true
    virsh -c qemu:///system pool-start "$POOL_NAME" >/dev/null
    virsh -c qemu:///system pool-autostart "$POOL_NAME" >/dev/null
    ok "storage pool '$POOL_NAME' -> $POOL_PATH"
  fi
  mountpoint -q "$POOL_PATH" \
    && ok "$POOL_PATH is its own volume" \
    || warn "$POOL_PATH is on the root filesystem - run 'datavg' first or VM images fill /"
}

# =========================================================================================
# /etc/hosts from the single address file. A bare-metal host had no step that did this -
# host-4's entry was added by hand, which worked and was not reproducible. It became
# load-bearing the moment MIRROR_URL named svc-repo-01 instead of an IP: without it, apt
# points at a host the machine cannot resolve. VMs get the same block from cloud-init.
cmd_hosts() {
  need_root hosts
  local aa="$SELF/../enclave/apply-addresses.sh"
  [ -x "$aa" ] || die "no apply-addresses.sh at $aa"
  "$aa" apply
}

cmd_trustca() {
  need_root trustca
  # Delegates to ca.sh so there is ONE implementation of "what does this machine trust".
  # This used to install a single hard-coded root-ca.crt, which quietly made the enclave CA
  # the only PKI the build could ever use. A site running DoD PKI drops its roots into
  # trust-anchors/ and needs no change here.
  local ca="$SELF/../enclave/ca.sh"
  [ -x "$ca" ] || die "no ca.sh at $ca"
  "$ca" trust
}


# =========================================================================================
cmd_keyonly() {
  # No load_params: this step needs nothing from the params file, and requiring one would
  # stop it running on stage-01 and build-01, which have no services-params.env and are
  # exactly the machines that turned out to need it. Its own guard below is the safety.
  need_root keyonly
  local u="${SUDO_USER:-$(id -un)}" home ak
  home=$(getent passwd "$u" | cut -d: -f6)
  ak="$home/.ssh/authorized_keys"

  # NEVER disable password auth on a machine nobody can key into. This check is the whole
  # safety of this subcommand: get it wrong on an air-gapped host with no default route and
  # the only way back is the physical console.
  [ -r "$ak" ] || die "$u has no $ak - refusing to disable password auth.
       You would lock yourself out of a machine with no default route."
  local n; n=$(grep -cE '^(ssh|ecdsa)-' "$ak" 2>/dev/null || true)
  [ "${n:-0}" -ge 1 ] || die "$ak contains no public keys - refusing."
  ok "$u has $n key(s) in authorized_keys"

  # LIST them, do not just count them. The count guard only proves the person running this
  # can still get in - it says nothing about anyone else. build-01 passed that check with a
  # single key and locked the operator out anyway, because the key it had was another
  # machine's. After this runs, these are the ONLY ways into the host.
  say ""
  say "    After this, the ONLY ways into $(hostname) are:"
  awk '{ printf "      %s  %s\n", $1, $NF }' "$ak" | while read -r l; do say "$l"; done
  say ""
  say "    If anyone who needs access is not on that list, add their key FIRST."
  say ""

  # WHY THIS FILE AND NOT A HIGHER-NUMBERED ONE: sshd is FIRST-MATCH-WINS, not last. A
  # 99-*.conf would be read AFTER 50-cloud-init.conf and lose. cloud-init's file is where
  # the 'yes' lives, so that is where the 'no' has to go - anything else leaves two files
  # disagreeing and the wrong one winning silently.
  local f=/etc/ssh/sshd_config.d/50-cloud-init.conf
  if [ -f "$f" ] && ! grep -q '^PasswordAuthentication yes' "$f"; then
    skip "password auth already disabled"
  else
    [ -f "$f" ] && cp "$f" "$f.bak-$(date +%Y%m%d%H%M%S)"
    cat > "$f" <<'CONF'
# Key-only SSH. Overwrites cloud-init's PasswordAuthentication yes.
#
# sshd is FIRST-MATCH-WINS: this file (50-) is read before 60-cloudimg-settings.conf, so
# whatever it says here decides, and a higher-numbered file cannot override it. That is why
# the setting lives here rather than in a 99-*.conf.
PasswordAuthentication no
KbdInteractiveAuthentication no
CONF
    chmod 0644 "$f"
    ok "wrote $f"
  fi

  sshd -t || die "sshd config is invalid - NOT reloading. Fix it before disconnecting."
  ok "sshd -t passed"
  systemctl reload ssh 2>/dev/null || systemctl reload sshd
  ok "sshd reloaded (existing sessions survive a reload)"

  local offered
  offered=$(ssh -o PreferredAuthentications=none -o StrictHostKeyChecking=no \
                -o BatchMode=yes -o ConnectTimeout=5 "$u@127.0.0.1" true 2>&1 \
            | grep -o '(.*)' | tr -d '()')
  case "$offered" in
    publickey) ok "verified: this host now offers publickey only" ;;
    *password*) warn "still offering: $offered - check for another PasswordAuthentication line" ;;
    *) say "offered methods: ${offered:-could not probe}" ;;
  esac
}

# =========================================================================================
cmd_tmux() {
  need_root tmux; load_params
  local pkgs="tmux ncurses-term"
  local missing=""
  for _p in $pkgs; do dpkg -s "$_p" >/dev/null 2>&1 || missing="$missing $_p"; done
  if [ -n "$missing" ]; then
    say "installing:$missing"
    # ncurses-term is NOT optional. It provides the tmux-256color terminfo entry, and without
    # it tmux refuses to start entirely - "missing or unsuitable terminal" - rather than
    # falling back. The Minimal cloud image does not ship it.
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $missing \
      || die "could not install$missing - is apt pointed at a working mirror?"
  else
    skip "tmux and ncurses-term already installed"
  fi

  local src="$SELF/../enclave/tmux.conf"
  [ -r "$src" ] || die "no tmux.conf at $src"
  if [ -f /etc/tmux.conf ] && diff -q "$src" /etc/tmux.conf >/dev/null 2>&1; then
    skip "/etc/tmux.conf already current"
  else
    install -m 0644 "$src" /etc/tmux.conf
    ok "installed /etc/tmux.conf"
  fi
  infocmp tmux-256color >/dev/null 2>&1 \
    && ok "tmux-256color terminfo present" \
    || warn "tmux-256color terminfo MISSING - tmux will not start"
}

# =========================================================================================
cmd_verify() {
  load_params
  local fail=0
  echo; echo "  ---- step 03 verification on $(hostname) ----"

  grep -q "$MIRROR_URL" /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null \
    && ok "apt -> $MIRROR_URL" || { warn "apt does not point at the mirror"; fail=1; }

  ip route | grep -q '^default' \
    && { warn "host HAS a default route - it is not air-gapped"; fail=1; } \
    || ok "no default route"

  command -v virsh >/dev/null \
    && ok "virsh $(virsh --version)" || { warn "virsh missing"; fail=1; }

  # Do NOT test 'systemctl is-active libvirtd'. libvirt is socket-activated on 24.04:
  # libvirtd.service stays inactive until something connects, so straight after a reboot that
  # check reports a healthy host as broken - and then every later virsh check fails too,
  # because the daemon it was about to start had not started yet. Ask virsh instead; it is
  # the thing we actually depend on, and connecting is what triggers the activation.
  if virsh -c qemu:///system version >/dev/null 2>&1; then
    ok "libvirt reachable (socket-activated; libvirtd.service may read inactive until used)"
  else
    warn "cannot connect to qemu:///system"; fail=1
  fi
  [ -c /dev/kvm ] && ok "/dev/kvm present" || { warn "/dev/kvm missing"; fail=1; }

  # Both halves matter. 'inactive' today with 'autostart yes' is not fixed - it is a virbr0 on
  # 192.168.122.1 waiting for the next boot that happens to start it.
  if virsh -c qemu:///system net-info default >/dev/null 2>&1; then
    local nstate nauto
    nstate=$(virsh -c qemu:///system net-info default 2>/dev/null | awk '/^Active:/{print $2}')
    nauto=$(virsh -c qemu:///system net-info default 2>/dev/null | awk '/^Autostart:/{print $2}')
    if [ "$nstate" = "no" ] && [ "$nauto" = "no" ]; then
      ok "default NAT network inactive and autostart off"
    else
      warn "default NAT network: active=$nstate autostart=$nauto - run 'libvirt' to disable it"
      warn "    autostart=yes means virbr0/192.168.122.1 returns on a later boot"
      fail=1
    fi
  fi

  ip -br addr show "$BRIDGE_NAME" >/dev/null 2>&1 \
    && ok "$BRIDGE_NAME up: $(ip -br addr show "$BRIDGE_NAME" | awk '{print $3}')" \
    || warn "$BRIDGE_NAME not present - run 'bridge' from an interactive session"

  local spec name size mnt
  for spec in $DATA_LVS; do
    IFS=: read -r name size mnt <<< "$spec"
    if mountpoint -q "$mnt" 2>/dev/null; then
      ok "$mnt mounted ($(findmnt -no SIZE "$mnt"), $(findmnt -no OPTIONS "$mnt" | cut -d, -f1-3))"
    else
      warn "$mnt NOT mounted"; fail=1
    fi
  done

  grep -q '^crypt-data.*nofail' /etc/crypttab 2>/dev/null \
    && ok "crypt-data unlocks by keyfile with nofail" \
    || warn "crypt-data is not on the keyfile - boot will prompt twice"

  echo
  [ "$fail" -eq 0 ] && ok "step 03 complete" || warn "step 03 INCOMPLETE - see above"
  return "$fail"
}

# =========================================================================================
case "${1:-}" in
  apt)     cmd_apt ;;
  libvirt) cmd_libvirt ;;
  datavg)  cmd_datavg ;;
  bridge)  cmd_bridge ;;
  pool)    cmd_pool ;;
  tmux)    cmd_tmux ;;
  hosts)   cmd_hosts ;;
  trustca) cmd_trustca ;;
  keyonly) cmd_keyonly ;;
  verify)  cmd_verify ;;
  all)     cmd_hosts; cmd_trustca; cmd_apt; cmd_libvirt; cmd_datavg; cmd_pool; cmd_tmux; cmd_verify ;;
  *)       sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
