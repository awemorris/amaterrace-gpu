#!/bin/bash
# Runs standalone out-of-context synthesis for atg_mc_l2
set -eu
trap 'sync' EXIT
root=$(cd "$(dirname -- "$0")/.." && pwd)
out=$root/build/vivado/atg_mc_l2
mkdir -p "$out"

cd "$out" && "$root/tools/vivado-cmd.sh" -mode batch -nojournal -log vivado.log -source "$root/tools/vivado-synth-l2.tcl" -tclargs "$root" "$out" </dev/null
sync
