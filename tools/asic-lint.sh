#!/bin/bash
# asic-lint.sh: Run the ASIC 5nm 1.5 GHz High-Frequency Architecture Linter
set -eu
if [ $# -lt 1 ]; then
    echo "Usage: tools/asic-lint.sh <module_name> [clock_period_ns] [extra_verilog_defines]"
    echo "Example: tools/asic-lint.sh atg_fmt_cvt 4.000"
    exit 1
fi

mod=$1
period=${2:-4.000}
defines=${3:-}

root=$(cd "$(dirname -- "$0")/.." && pwd)
tools/vivado-cmd.sh -source tools/asic-lint.tcl -tclargs "$mod" "$period" "$defines"
