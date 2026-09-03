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
apt:
  preserve_sources_list: false
  primary:
    - arches: [default]
      uri: $VM_MIRROR_URL
  security:
    - arches: [default]
      uri: $VM_MIRROR_URL

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

cloud-localds -N "$TMP/network-config" "$SEED" "$TMP/user-data" "$TMP/meta-data"
ok "seed    : $SEED"

# ---- define and start --------------------------------------------------------------------
virt-install \
  --name "$VM" \
  --memory "$RAM_MB" --vcpus "$VCPUS" \
  --cpu host-passthrough \
  --os-variant "${VM_OSVARIANT:-ubuntu24.04}" \
  --disk "path=$DISK,format=qcow2,bus=virtio" \
  --disk "path=$SEED,device=cdrom" \
  --network "bridge=$BRIDGE,model=virtio" \
  --graphics none --console pty,target_type=serial \
  --import --noautoconsole
ok "defined and started"

virsh autostart "$VM" >/dev/null
ok "autostart enabled"

say ""
say "cloud-init takes a minute or two. Watch it:"
say "    sudo virsh console $VM        (escape is Ctrl-])"
say "Then, from anywhere on the subnet:"
say "    ssh ${VM_USER:-encadmin}@$ADDRESS 'cat /etc/enclave-build-info'"
