#!/bin/bash
# High-speed Out-Of-Context (OOC) Vivado synthesis & timing analysis
# Usage: tools/ooc-synth.sh [MODULE] [PERIOD_NS]
set -eu

MODULE=${1:-am_fpu_core}
PERIOD=${2:-5.000}
PART=${PART:-xc7k325tffg900-2}

root=$(cd "$(dirname -- "$0")/.." && pwd)
out=$root/build/vivado/ooc_${MODULE}
mkdir -p "$out"

settings=/home/awe/opt/amd/2026.1/Vivado/settings64.sh
[ -f "$settings" ] || { echo "no $settings" >&2; exit 1; }
. "$settings"
[ -f "$HOME/Xilinx.lic" ] && export XILINXD_LICENSE_FILE=$HOME/Xilinx.lic
export LD_LIBRARY_PATH=$XILINX_VIVADO/lib/lnx64.o/Ubuntu/24${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

cat << 'EOF' > "$out/synth.tcl"
set module $env(MODULE)
set period $env(PERIOD)
set part $env(PART)
set root $env(ROOT)
set out $env(OUT)

# Read verilog sources
set v_files [concat \
	[glob -nocomplain $root/rtl/library/arith/*.v] \
	[glob -nocomplain $root/rtl/library/fp/*.v] \
	[glob -nocomplain $root/rtl/library/mem/*.v] \
	[glob -nocomplain $root/rtl/library/bus/*.v] \
	[glob -nocomplain $root/rtl/gpu/tu/*.v] \
	[glob -nocomplain $root/rtl/gpu/cp/*.v] \
	[glob -nocomplain $root/rtl/gpu/su/*.v] \
	[glob -nocomplain $root/rtl/gpu/rop/*.v] \
	[glob -nocomplain $root/rtl/gpu/rx/*.v] \
	[glob -nocomplain $root/rtl/gpu/fmt/*.v] \
	[glob -nocomplain $root/rtl/gpu/dc/*.v] \
	[glob -nocomplain $root/rtl/gpu/mc/*.v] \
	[glob -nocomplain $root/rtl/gpu/blt/*.v] \
]
foreach f $v_files {
	read_verilog $f
}

set_property include_dirs [list "$root/include"] [current_fileset]

set synth_define "SYNTH_GENERIC"
if {[string match "*7k*" $part]} {
	set synth_define "SYNTH_KINTEX7"
} elseif {[string match "*zu*" $part]} {
	set synth_define "SYNTH_ZYNQ_ULTRASCALE"
}

puts "Starting OOC synthesis for $module with period $period ns ($synth_define)..."
if {$module == "am_fpu_core"} {
	synth_design -top $module -part $part -mode out_of_context -verilog_define $synth_define -generic LAT=6
} else {
	synth_design -top $module -part $part -mode out_of_context -verilog_define $synth_define
}

create_clock -period $period -name clk [get_ports clk]

report_timing_summary -max_paths 10 -file "$out/timing_summary.rpt"
report_utilization -file "$out/utilization.rpt"

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "OOC_RESULT: MODULE=$module PERIOD=${period}ns WNS=${wns}ns"
EOF

MODULE=$MODULE PERIOD=$PERIOD PART=$PART ROOT=$root OUT=$out \
vivado -mode batch -nojournal -log "$out/vivado.log" -source "$out/synth.tcl"

grep "OOC_RESULT:" "$out/vivado.log" || true
grep -A 10 "Intra Clock Table" "$out/timing_summary.rpt" || true
grep -A 25 "Slack (VIOLATED)" "$out/timing_summary.rpt" || grep -A 25 "Slack (MET)" "$out/timing_summary.rpt" || true
