#!/bin/bash
# Runs standalone out-of-context synthesis for atg_mc_l2
set -eu
root=$(cd "$(dirname -- "$0")/.." && pwd)
out=$root/build/vivado/atg_mc_l2
mkdir -p "$out"

if ! command -v vivado >/dev/null 2>&1; then
	settings=${VIVADO:-$HOME/opt/amd/2026.1/Vivado/settings64.sh}
	[ -f "$settings" ] || { echo "vivado-synth-l2: no vivado on PATH and no $settings" >&2; exit 1; }
	. "$settings"
fi
if [ -z "${XILINXD_LICENSE_FILE:-}" ] && [ -f "$HOME/Xilinx.lic" ]; then
	XILINXD_LICENSE_FILE=$HOME/Xilinx.lic
	export XILINXD_LICENSE_FILE
fi
: "${XILINX_VIVADO:=$(dirname -- "$(dirname -- "$(command -v vivado)")")}"
if ! /sbin/ldconfig -p | grep -q 'libncurses\.so\.5 '; then
	LD_LIBRARY_PATH=$XILINX_VIVADO/lib/lnx64.o/Ubuntu/24${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
	export LD_LIBRARY_PATH
fi

cd "$out" && vivado -mode batch -nojournal -log vivado.log -source "$root/tools/vivado-synth-l2.tcl" -tclargs "$root" "$out" </dev/null
