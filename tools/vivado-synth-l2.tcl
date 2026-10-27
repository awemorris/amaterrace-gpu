# Standalone Out-Of-Context synthesis of atg_mc_l2
set root [lindex $argv 0]
set out [lindex $argv 1]
set part "xc7k325tffg900-2"

file mkdir $out
set_part $part

read_verilog [list \
    [file join $root rtl library arith am_add.v] \
    [file join $root rtl gpu mc atg_mc_l2.v] \
]

# Synthesize with 8KB KC705 configuration (WAYS=4, SET_W=5)
synth_design -top atg_mc_l2 -part $part -mode out_of_context \
    -generic WAYS=4 -generic SET_W=5 -verilog_define SYNTH_KINTEX7

report_utilization -file [file join $out l2_8k_utilization.rpt]

# Create a 200 MHz clock constraint for timing evaluation
create_clock -period 5.000 -name clk [get_ports clk]
report_timing_summary -max_paths 10 -file [file join $out l2_8k_timing_summary.rpt]

puts "vivado-synth-l2: standalone L2 8KB synthesis finished successfully"
