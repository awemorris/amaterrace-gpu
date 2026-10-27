#!/bin/bash
set -eu
root=$(cd "$(dirname -- "$0")/.." && pwd)
if ! command -v vivado >/dev/null 2>&1; then
	settings=${VIVADO:-$HOME/opt/amd/2026.1/Vivado/settings64.sh}
	[ -f "$settings" ] || { echo "no vivado and no $settings" >&2; exit 1; }
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
out=$root/build/vivado/kc705_ip
mkdir -p "$out"
vivado -mode batch -nojournal -log "$out/ip_update.log" -source "$root/boards/kc705/ip.tcl" -tclargs "$out" "$@"
