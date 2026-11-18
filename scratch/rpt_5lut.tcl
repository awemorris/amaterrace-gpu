set top test_fadd_full
set part xc7k325tffg900-2
read_verilog [glob rtl/library/arith/*.v]
read_verilog scratch/test_fadd_full.v
synth_design -top $top -part $part -mode out_of_context -include_dirs include -verilog_define SYNTH_KINTEX7
create_clock -period 4.000 -name clk [get_ports clk]

set p [lindex [get_timing_paths -from [get_pins g_lat4.r_sum3_reg[27]/C] -to [get_pins g_lat4.r_or_reg[10]/D]] 0]
if {$p != ""} {
    puts [report_timing -of_objects $p -return_string]
}
