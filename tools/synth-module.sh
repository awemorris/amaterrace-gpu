#!/bin/bash
# Fast module-level OOC synthesis and timing check
set -eu
if [ $# -lt 1 ]; then
    echo "Usage: tools/synth-module.sh <module_name> [clock_period_ns] [extra_verilog_defines]"
    exit 1
fi
mod=$1
period=${2:-5.000}
defines=${3:-}
root=$(cd "$(dirname -- "$0")/.." && pwd)

tools/vivado-cmd.sh -source tools/synth-module.tcl -tclargs "$mod" "" "$period" "$defines"
