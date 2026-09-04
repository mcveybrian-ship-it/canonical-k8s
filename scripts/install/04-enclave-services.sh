#!/usr/bin/env bash
# =========================================================================================
# 04-enclave-services.sh - stand up the services the enclave runs on itself.
#
#     MACHINE: runs ON the service VM being configured.
#
#     ./04-enclave-services.sh contracts   Ubuntu Pro air-gapped contracts server
#     ./04-enclave-services.sh pro         point the pro client at it, and attach
#     ./04-enclave-services.sh verify      prove what is running, change nothing
#
# Everything here assumes svc-repo-01 is already serving - it is where the packages and the
# carried .debs come from. See docs/airgap-media.md.
# =========================================================================================
set -euo pipefail

CONTRACTS_CONF="${CONTRACTS_CONF:-/etc/ubuntu-advantage/airgapped-contracts.yaml}"
CONTRACTS_PORT="${CONTRACTS_PORT:-8484}"
CONTRACTS_USER="${CONTRACTS_USER:-contracts}"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
skip() { printf '  [--] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '\n  [x] %s\n\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $0 $*"; }

# =========================================================================================
cmd_contracts() {
  need_root contracts

  command -v contracts-airgapped >/dev/null \
    || die "contracts-airgapped is not installed. It cannot come from the mirror - it is a
       Launchpad PPA package the enclave has no route to. Fetch it from the repo server:
         curl -fO http://svc-repo-01.enclave.internal/debs/contracts-airgapped_1.8.1_amd64.deb
         sudo apt-get install -y ./contracts-airgapped_1.8.1_amd64.deb"

  [ -f "$CONTRACTS_CONF" ] \
    || die "no config at $CONTRACTS_CONF.
       Generate it on stage-01 with scripts/transfer/make-contracts-config.sh and copy it
       here - it is a credential, so scp it, do not serve it over HTTP."

  # The whole point of the file is that its aptURLs name the in-gap repo. A config that still
  # points at Canonical produces a contracts server that answers and entitles nothing.
  local n
  n=$(grep -c 'aptURL:.*enclave' "$CONTRACTS_CONF" 2>/dev/null || true)
  [ "${n:-0}" -ge 4 ] \
    || die "only ${n:-0} of 4 aptURLs point at the enclave in $CONTRACTS_CONF.
       Regenerate it on stage-01; see airgapped-setup-machine/README.md §6.4a."
  ok "config has $n enclave aptURLs"

  # A dedicated unprivileged account. The port is above 1024 so nothing here needs root, and
  # this process reads a file that maps contract tokens to entitlements.
  if id "$CONTRACTS_USER" >/dev/null 2>&1; then
    skip "user $CONTRACTS_USER exists"
  else
    useradd --system --no-create-home --shell /usr/sbin/nologin "$CONTRACTS_USER"
    ok "created system user $CONTRACTS_USER"
  fi
  # 0640 root:contracts - readable by the service, not by everyone. It stays a credential.
  chown "root:$CONTRACTS_USER" "$CONTRACTS_CONF"
  chmod 0640 "$CONTRACTS_CONF"
  ok "$CONTRACTS_CONF is 0640 root:$CONTRACTS_USER"

  # The package ships ONLY a binary - no unit, no config, no service. Left as it comes, the
  # contracts server is something someone has to remember to start by hand after every reboot,
  # and the failure mode is that `pro attach` stops working across the whole enclave with no
  # obvious cause.
  cat > /etc/systemd/system/contracts-airgapped.service <<UNIT
[Unit]
Description=Ubuntu Pro air-gapped contracts server
Documentation=https://canonical.com/ubuntu/pro
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$CONTRACTS_USER
Group=$CONTRACTS_USER
ExecStart=/usr/bin/contracts-airgapped --input $CONTRACTS_CONF --port $CONTRACTS_PORT
Restart=on-failure
RestartSec=5

# contracts-airgapped GENERATES AND STORES A ROOT SIGNING KEY under \$HOME, in config.RootKey().
# Undocumented, and the failure is a Go panic rather than a message:
#     panic: mkdir /home/contracts: permission denied
# A --no-create-home system account has nowhere to put it, and ProtectHome=yes would block
# /home regardless. StateDirectory gives it /var/lib/contracts-airgapped at 0700 owned by the
# service user - created by systemd, removed with the unit, and exempt from ProtectHome.
StateDirectory=contracts-airgapped
StateDirectoryMode=0700
Environment=HOME=/var/lib/contracts-airgapped
WorkingDirectory=/var/lib/contracts-airgapped

# This process reads a file mapping contract tokens to entitlements and listens on the
# network. It needs to read one file and open one socket; everything else is denied.
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
MemoryDenyWriteExecute=yes
LockPersonality=yes
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
UNIT
  ok "wrote /etc/systemd/system/contracts-airgapped.service"

  systemctl daemon-reload
  systemctl enable --now contracts-airgapped >/dev/null 2>&1 || true
  sleep 2
  if systemctl is-active --quiet contracts-airgapped; then
    ok "contracts-airgapped running on :$CONTRACTS_PORT, enabled at boot"
  else
    warn "service did not start. Diagnose with:"
    say "    sudo systemctl status contracts-airgapped --no-pager"
    say "    sudo journalctl -u contracts-airgapped -n 40 --no-pager"
    die "contracts-airgapped failed to start"
  fi
}

# =========================================================================================
cmd_pro() {
  need_root pro
  local url="${CONTRACTS_URL:-http://svc-mgmt-01.enclave.internal:$CONTRACTS_PORT}"
  local tokfile="${PRO_TOKEN_FILE:-}"
  if [ -z "$tokfile" ]; then
    local h; h=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
    tokfile="${h:-$HOME}/.pro-contract-token"
  fi

  command -v pro >/dev/null || die "ubuntu-advantage-tools is not installed"

  # Point the client at the enclave's own contracts server. Left at the default the client
  # talks to contracts.canonical.com, which in here simply times out - and the error says
  # nothing about the contract server being the thing that should have been configured.
  local conf=/etc/ubuntu-advantage/uaclient.conf
  if grep -q "^contract_url: *$url\s*$" "$conf" 2>/dev/null; then
    skip "contract_url already $url"
  else
    cp "$conf" "$conf.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    if grep -q '^contract_url:' "$conf" 2>/dev/null; then
      sed -i "s|^contract_url:.*|contract_url: $url|" "$conf"
    else
      printf 'contract_url: %s\n' "$url" >> "$conf"
    fi
    ok "contract_url -> $url"
  fi

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url/v1/resources" || true)
  [ "${code:-000}" = "200" ] \
    || die "the contracts server did not answer at $url/v1/resources (got ${code:-no response}).
       Is contracts-airgapped running on svc-mgmt-01, and does this machine resolve
       svc-mgmt-01.enclave.internal? Check: getent hosts svc-mgmt-01.enclave.internal"
  ok "contracts server reachable at $url"

  if pro status --format json 2>/dev/null | grep -q '"attached": *true'; then
    skip "already attached"; return 0
  fi

  [ -r "$tokfile" ] || die "no token file at $tokfile.
       The token goes in a FILE, not on the command line - 'pro attach <token>' puts it in
       ps and in shell history. Create it:
         install -m 600 /dev/null $tokfile
         read -rs -p 'token: ' T && printf '%s\n' \"\$T\" > $tokfile && unset T"
  [ "$(stat -c '%a' "$tokfile")" = "600" ] || die "$tokfile must be mode 600 - it is a credential"

  # --no-auto-enable deliberately. Attaching and ENABLING are separate decisions: enabling
  # fips-updates replaces the kernel and needs a reboot, and usg pulls in the STIG tooling.
  # Both belong in step 05 hardening, where the before/after evidence gets captured - not as
  # a side effect of attaching.
  local ac; ac=$(mktemp); chmod 600 "$ac"; trap 'rm -f "$ac"' EXIT
  printf 'token: %s\n' "$(head -1 "$tokfile" | tr -d '[:space:]')" > "$ac"
  if pro attach --attach-config "$ac" --no-auto-enable >/dev/null 2>&1; then
    ok "attached (no services auto-enabled - that is step 05)"
  else
    rm -f "$ac"; trap - EXIT
    die "pro attach failed. Run it by hand to see why:
         sudo pro attach --attach-config <file> --no-auto-enable"
  fi
  rm -f "$ac"; trap - EXIT

  say ""
  say "  entitlements this machine can now enable:"
  pro status 2>/dev/null | sed -n '/SERVICE/,$p' | head -14 | sed 's/^/    /'
}

# =========================================================================================
cmd_verify() {
  local fail=0
  echo; echo "  ---- step 04 verification on $(hostname) ----"

  if command -v contracts-airgapped >/dev/null; then ok "contracts-airgapped installed"
  else warn "contracts-airgapped not installed"; fail=1; fi

  if systemctl is-active --quiet contracts-airgapped 2>/dev/null; then
    ok "service active"
    systemctl is-enabled --quiet contracts-airgapped 2>/dev/null \
      && ok "enabled at boot" || { warn "NOT enabled at boot"; fail=1; }
  else warn "service not active"; fail=1; fi

  if ss -ltn 2>/dev/null | grep -q ":$CONTRACTS_PORT"; then ok "listening on :$CONTRACTS_PORT"
  else warn "nothing listening on :$CONTRACTS_PORT"; fail=1; fi

  # Answering is not the same as answering correctly, but a non-empty HTTP response at least
  # proves the process is serving rather than merely running.
  # NOT `|| echo 000`: curl PRINTS 000 on failure AND exits non-zero, so the fallback
  # concatenates into "000000" - which is not equal to "000", so the check passes on a
  # connection that never happened. Exactly the trap `grep -c || echo 0` set yesterday.
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$CONTRACTS_PORT/" || true)
  case "${code:-000}" in
    000|"") warn "no HTTP response on :$CONTRACTS_PORT"; fail=1 ;;
    *)      ok "responds on :$CONTRACTS_PORT (HTTP $code)" ;;
  esac

  echo
  [ "$fail" -eq 0 ] && ok "contracts server ready" || warn "INCOMPLETE - see above"
  return "$fail"
}

case "${1:-}" in
  contracts) cmd_contracts ;;
  pro)       cmd_pro ;;
  verify)    cmd_verify ;;
  *)         sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
