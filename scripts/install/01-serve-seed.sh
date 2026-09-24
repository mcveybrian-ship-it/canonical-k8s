#!/usr/bin/env bash
#
# 01 - Serve the pathfinder autoinstall seed over HTTP.
#
# Run on a laptop on the same network as the pathfinder. The installer fetches user-data from
# here, and the late-commands pull the step 01 scripts from here too - so the machine comes up
# with everything already on it and there is no USB shuffle.
# Connected side ONLY: production installs are USB-only (docs/airgap-media.md section 3).
#
# Usage:
#   ./01-serve-seed.sh [-p PORT] [-d TEMPLATE_DIR] [-f USER_DATA_FILE]
#
set -euo pipefail
PORT=3003
DIR=""
FILE=""
while getopts ":p:d:f:h" opt; do
  case "$opt" in
    p) PORT="$OPTARG" ;;
    d) DIR="$OPTARG" ;;
    f) FILE="$OPTARG" ;;
    h) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: -$OPTARG" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="${DIR:-$HERE/01-pathfinder-autoinstall}"
# http.server publishes the whole directory it runs in, so serve a temp copy holding ONLY
# the four files the installer needs - never the repo checkout.
SERVE="$(mktemp -d)"; trap 'rm -rf "$SERVE"' EXIT

cp "${FILE:-$TPL/user-data}" "$SERVE/user-data"
# NoCloud requires meta-data to exist even when it is empty.
touch "$SERVE/meta-data"
cp "$HERE/01-hw-inventory.sh" "$HERE/01-capability-test.sh" "$SERVE/"

if grep -n 'REPLACE-ME' "$SERVE/user-data"; then
  echo >&2
  echo "ERROR: unfilled REPLACE-ME fields above. Fill them in:" >&2
  echo "       $TPL/user-data" >&2
  echo "       See docs/01-pathfinder.md." >&2
  exit 1
fi

# This machine's address on its default-route interface - normally the one the pathfinder
# reaches it on. 'ip route get' only consults the routing table; no packet is sent.
IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
IP="${IP:-<this-machine-ip>}"

cat <<INFO

Serving $SERVE on port $PORT
Files: user-data  meta-data  01-hw-inventory.sh  01-capability-test.sh

At the pathfinder's GRUB menu press 'e' and append to the linux line:

    autoinstall ds=nocloud-net;s=http://$IP:$PORT/

then Ctrl-X to boot. Leave this running until the install finishes.
Ctrl-C to stop.

INFO

# Plain HTTP, no authentication: while this runs, anyone on the subnet can fetch user-data,
# which carries the admin password hash. Stop it as soon as the install has finished.
cd "$SERVE"
python3 -m http.server "$PORT" 2>/dev/null || python -m http.server "$PORT"
