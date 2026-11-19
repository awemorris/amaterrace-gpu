#!/bin/bash
set -eu
trap 'sync' EXIT
root=$(cd "$(dirname -- "$0")/.." && pwd)
out=$root/build/vivado/kc705_ip
mkdir -p "$out"
"$root/tools/vivado-cmd.sh" -mode batch -nojournal -log "$out/ip_update.log" -source "$root/boards/kc705/ip.tcl" -tclargs "$out" "$@"
sync
