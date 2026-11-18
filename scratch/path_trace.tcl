set root [file normalize [file join [file dirname [info script]] ".."]]
set part xc7k325tffg900-2
set incdirs [list [file join $root include]]
set v_files [glob -nocomplain [file join $root rtl library * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl library *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl common *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu blt *.v]]
foreach f [lsort -unique $v_files] { read_verilog $f }
synth_design -top atg_blt -part $part -mode out_of_context -include_dirs $incdirs -verilog_define SYNTH_KINTEX7
create_clock -period 4.000 -name clk [get_ports clk]
puts "=== PATH 1: s_op_reg[8] to dst_row_b_reg[31] ==="
puts [report_timing -from [get_pins b2d/cfg/s_op_reg[8]/C] -to [get_pins b2d/dst_row_b_reg[31]/D] -return_string]
puts "=== PATH 2: s_op_reg[8] to dacc/r_hi_reg[15] ==="
puts [report_timing -from [get_pins b2d/cfg/s_op_reg[8]/C] -to [get_pins b2d/dacc/r_hi_reg[15]/D] -return_string]
exit 0
