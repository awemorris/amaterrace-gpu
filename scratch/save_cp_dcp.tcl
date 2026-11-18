set root [pwd]
set top "atg_cp"
set part xc7k325tffg900-2
set incdirs [list [file join $root include]]
set v_files [glob -nocomplain [file join $root rtl library * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl library *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl bsp * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl bsp *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl *.v]]
set unique_files [lsort -unique $v_files]
foreach f $unique_files {
    read_verilog $f
}
synth_design -top $top -part $part -mode out_of_context -include_dirs $incdirs -verilog_define [list "SYNTH_KINTEX7"]
create_clock -period 4.000 [get_ports clk]
write_checkpoint -force build/asic_lint/atg_cp/atg_cp.dcp
EOF
