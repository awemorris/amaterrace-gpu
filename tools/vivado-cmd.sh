#!/bin/bash
# Wrapper to run Vivado batch scripts with strict host resource limits:
#   1. Maximum 1 Vivado process on the host at any time (flock /tmp/vivado.lock)
#   2. Maximum 2 threads (general.maxThreads=2, synth.maxThreads=1, locked in Vivado_init.tcl)
#   3. Mandatory 'sync' after execution to flush disk writeback cache
# Copyright (C) 2026 Awe Morris; SPDX-License-Identifier: Zlib
set -eu

trap 'sync' EXIT

root=$(cd "$(dirname -- "$0")/.." && pwd)
settings=${VIVADO:-$HOME/opt/amd/2026.1/Vivado/settings64.sh}
[ -f "$settings" ] || { echo "vivado-cmd: no $settings" >&2; exit 1; }
. "$settings"

if [ -z "${XILINXD_LICENSE_FILE:-}" ] && [ -f "$HOME/Xilinx.lic" ]; then
	XILINXD_LICENSE_FILE=$HOME/Xilinx.lic
	export XILINXD_LICENSE_FILE
fi

REAL_VIVADO="$HOME/opt/amd/2026.1/Vivado/bin/vivado"
if [ ! -x "$REAL_VIVADO" ]; then
	echo "vivado-cmd: binary not found at $REAL_VIVADO" >&2
	exit 1
fi

XILINX_VIVADO=$(dirname -- "$(dirname -- "$REAL_VIVADO")")
export XILINX_VIVADO
if ! /sbin/ldconfig -p | grep -q 'libncurses\.so\.5 '; then
	LD_LIBRARY_PATH=$XILINX_VIVADO/lib/lnx64.o/Ubuntu/24${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
	export LD_LIBRARY_PATH
fi

# Ensure Vivado_init.tcl is present and enforces 2-thread / 1-synth-thread cap
for init_dir in "$HOME/.Xilinx/Vivado" "$HOME/.Xilinx/Vivado/2026.1"; do
	mkdir -p "$init_dir"
	init_tcl="$init_dir/Vivado_init.tcl"
	if [ ! -s "$init_tcl" ]; then
		cat << 'EOF' > "$init_tcl"
set_param general.maxThreads 2
catch {set_param synth.maxThreads 1}
if {[info commands _amaterrace_orig_set_param] eq ""} {
    rename set_param _amaterrace_orig_set_param
    proc set_param {args} {
        if {[llength $args] >= 2} {
            set pname [lindex $args end-1]
            set pval  [lindex $args end]
            if {$pname eq "general.maxThreads"} {
                if {[string is integer -strict $pval] && $pval > 2} {
                    set args [lreplace $args end end 2]
                }
            } elseif {$pname eq "synth.maxThreads"} {
                if {[string is integer -strict $pval] && $pval > 1} {
                    set args [lreplace $args end end 1]
                }
            }
        }
        return [uplevel 1 [list _amaterrace_orig_set_param {*}$args]]
    }
}
EOF
	fi
done

export VIVADO_THREADS=2
export VIVADO_MAX_THREADS=2

has_mode=0
for arg in "$@"; do
	if [ "$arg" = "-mode" ]; then
		has_mode=1
		break
	fi
done

# Strictly limit to 1 Vivado process across the host, at most 2 threads, and sync before releasing lock
exec 9>/tmp/vivado.lock
flock -x 9

rc=0
if [ "$has_mode" -eq 1 ]; then
	"$REAL_VIVADO" "$@" </dev/null || rc=$?
else
	"$REAL_VIVADO" -mode batch -nojournal "$@" </dev/null || rc=$?
fi

sync
exit $rc
