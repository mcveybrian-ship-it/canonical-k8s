#!/usr/bin/env bash
# =========================================================================================
# 03-compose-vm.sh - compose one enclave VM from the Minimal cloud image.
#
#     MACHINE: runs ON the virtualisation host (host-4 for the service VMs).
#
#     sudo ./03-compose-vm.sh svc-mgmt-01
#     sudo ./03-compose-vm.sh svc-mgmt-01 -n        show what it would do, touch nothing
#     sudo ./03-compose-vm.sh svc-mgmt-01 --destroy remove it and its disk
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
DRY=0; DESTROY=0; VM=""

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" -eq 1 ]; then echo "  DRY: $*"; else "$@"; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY=1; shift ;;
    --destroy)    DESTROY=1; shift ;;
    -h|--help)    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           die "unknown option $1" ;;
    *)            VM="$1"; shift ;;
  esac
done
[ -n "$VM" ] || { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

[ -r "$ENCLAVE_DIR/enclave-addresses.env" ] || die "no enclave-addresses.env in $ENCLAVE_DIR"
[ -r "$ENCLAVE_DIR/vm-specs.env" ]          || die "no vm-specs.env in $ENCLAVE_DIR"
# shellcheck disable=SC1090
. "$ENCLAVE_DIR/enclave-addresses.env"
# shellcheck disable=SC1090
. "$ENCLAVE_DIR/vm-specs.env"

# svc-mgmt-01 -> SVC_MGMT_01
KEY_NAME="$(echo "$VM" | tr 'a-z-' 'A-Z_')"
ADDRESS="${!KEY_NAME:-}"
SPEC_VAR="VM_$KEY_NAME"; SPEC="${!SPEC_VAR:-}"
[ -n "$ADDRESS" ] || die "$VM has no address. Add $KEY_NAME to enclave-addresses.env."
[ -n "$SPEC" ]    || die "$VM has no spec. Add $SPEC_VAR to vm-specs.env."
IFS=: read -r VCPUS RAM_MB DISK_GB <<< "$SPEC"

POOL="${VM_POOL:?}"; BRIDGE="${VM_BRIDGE:?}"; DOMAIN="${ENCLAVE_DOMAIN:?}"
DISK="$POOL/$VM.qcow2"
SEED="$POOL/seed/$VM-seed.iso"

# ---- destroy ----------------------------------------------------------------------------
if [ "$DESTROY" -eq 1 ]; then
  [ "$(id -u)" -eq 0 ] || die "run with sudo"
  say "this DESTROYS $VM and $DISK"
  run virsh destroy "$VM" 2>/dev/null || true
  run virsh undefine "$VM" --nvram 2>/dev/null || true
  run rm -f "$DISK" "$SEED"
  ok "$VM removed"; exit 0
fi

[ "$DRY" -eq 1 ] || [ "$(id -u)" -eq 0 ] || die "run with sudo"

# ---- refuse to run on the wrong machine --------------------------------------------------
# Same guard as 03-host-services.sh: the VM's own host is identified by which address this
# machine holds, so a pasted command in the wrong window stops here.
if [ "$DRY" -eq 0 ] && ! ip -br addr | grep -qw "${HOST_4%%/*}"; then
  warn "this machine does not hold $HOST_4 - composing $VM somewhere unexpected?"
fi

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
run install -d -m 0711 "$POOL/seed"
# Log the serial console to a file as well as the pty. A VM with no default route that fails
# to bring up networking is invisible: no ssh, and 'virsh console' needs an interactive root
# session on the host. Without this the only evidence of what went wrong is gone the moment
# nobody was watching. Costs nothing; answers the question every time.
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
run qemu-img resize "$DISK" "${DISK_GB}G"
ok "disk    : $DISK (independent copy, sparse, grown to ${DISK_GB}G)"

# ---- cloud-init --------------------------------------------------------------------------
# The hosts block comes from apply-addresses.sh so there is exactly one renderer. A VM that
# writes its own copy is a second source of truth waiting to disagree.
HOSTS_BLOCK="$("$ENCLAVE_DIR/apply-addresses.sh" render | sed 's/^/      /')"
# Shared operator tmux config, same file the bare-metal hosts get.
TMUX_CONF=""
[ -r "$ENCLAVE_DIR/tmux.conf" ] && TMUX_CONF="$(sed 's/^/      /' "$ENCLAVE_DIR/tmux.conf")"
# The enclave root CA, so a VM trusts the PKI from its first boot rather than needing a visit.
# A machine that does not trust the root cannot reach an HTTPS mirror - and the failure looks
# like a certificate problem on the SERVER, which is where people look first.
# EVERY anchor in trust-anchors/, not just this CA's root. A site running DoD PKI drops its
# roots in there and composed VMs pick them up with no change here - which is the whole point
# of that directory being a directory.
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

package_update: true
packages: [$(echo "${VM_EXTRA_PACKAGES:-}" | tr ' ' '\n' | sed '/^$/d' | paste -sd, -)]

runcmd:
  - [ systemctl, enable, --now, ssh ]
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
virt-install \
  --name "$VM" \
  --memory "$RAM_MB" --vcpus "$VCPUS" \
  --cpu host-passthrough \
  --os-variant "${VM_OSVARIANT:-ubuntu24.04}" \
  "${FIRMWARE_ARGS[@]}" \
  --disk "path=$DISK,format=qcow2,bus=virtio" \
  --disk "path=$SEED,device=disk,bus=virtio,format=raw,readonly=on" \
  --network "bridge=$BRIDGE,model=virtio" \
  --graphics none \
  --console pty,target_type=serial \
  --serial "file,path=$LOGDIR/$VM-console.log" \
  --import --noautoconsole
ok "defined and started"

virsh autostart "$VM" >/dev/null
ok "autostart enabled"

# Now that qemu has created it, make the console log readable over ssh.
chmod 0644 "$LOGDIR/$VM-console.log" 2>/dev/null \
  && ok "console log readable: $LOGDIR/$VM-console.log" \
  || warn "could not chmod the console log - it will need sudo to read"

say ""
say "cloud-init takes a minute or two. Watch it:"
say "    sudo virsh console $VM        (escape is Ctrl-])"
say "Or read the console log, which needs no interactive session:"
say "    sudo tail -f $LOGDIR/$VM-console.log"
say "Then, from anywhere on the subnet:"
say "    ssh ${VM_USER:-encadmin}@$ADDRESS 'cat /etc/enclave-build-info'"
