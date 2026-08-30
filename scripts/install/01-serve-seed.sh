#!/usr/bin/env bash
#
# 01 - Serve the pathfinder autoinstall seed over HTTP.
#
# Run on a laptop on the same network as the pathfinder. The installer fetches user-data from
# here, and the late-commands pull the step 01 scripts from here too - so the machine comes up
# with everything already on it and there is no USB shuffle.
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
SERVE="$(mktemp -d)"; trap 'rm -rf "$SERVE"' EXIT

cp "${FILE:-$TPL/user-data}" "$SERVE/user-data"
touch "$SERVE/meta-data"
cp "$HERE/01-hw-inventory.sh" "$HERE/01-capability-test.sh" "$SERVE/"

if grep -n 'REPLACE-ME' "$SERVE/user-data"; then
  echo >&2
  echo "ERROR: unfilled REPLACE-ME fields above. Fill them in:" >&2
  echo "       $TPL/user-data" >&2
  echo "       See docs/01-pathfinder.md." >&2
  exit 1
fi

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

cd "$SERVE"
python3 -m http.server "$PORT" 2>/dev/null || python -m http.server "$PORT"
