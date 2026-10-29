#!/bin/bash
# Wrapper to run vivado batch scripts with proper environment
set -eu
root=$(cd "$(dirname -- "$0")/.." && pwd)
settings=${VIVADO:-$HOME/opt/amd/2026.1/Vivado/settings64.sh}
[ -f "$settings" ] || { echo "vivado-cmd: no $settings" >&2; exit 1; }
. "$settings"

if [ -z "${XILINXD_LICENSE_FILE:-}" ] && [ -f "$HOME/Xilinx.lic" ]; then
	XILINXD_LICENSE_FILE=$HOME/Xilinx.lic
	export XILINXD_LICENSE_FILE
fi
: "${XILINX_VIVADO:=$(dirname -- "$(dirname -- "$(command -v vivado)")")}"
if ! /sbin/ldconfig -p | grep -q 'libncurses\.so\.5 '; then
	LD_LIBRARY_PATH=$XILINX_VIVADO/lib/lnx64.o/Ubuntu/24${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
	export LD_LIBRARY_PATH
fi

export VIVADO_THREADS=${VIVADO_THREADS:-2}
export VIVADO_MAX_THREADS=${VIVADO_MAX_THREADS:-2}

exec vivado -mode batch "$@"
