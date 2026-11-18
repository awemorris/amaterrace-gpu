set top "atg_su"
set part "xc7k325tffg900-2"
set clk_period 5.000
set root [file normalize [file join [file dirname [info script]] ".."]]
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

synth_design -top $top -part $part -mode out_of_context -include_dirs $incdirs -verilog_define "SYNTH_KINTEX7"
create_clock -period $clk_period -name clk [get_ports clk]

set paths [get_timing_paths -max_paths 50 -slack_lesser_than 0]
puts "=== TOP 50 VIOLATIONS ==="
foreach p $paths {
    set slk [get_property SLACK $p]
    set src [get_property STARTPOINT_PIN $p]
    set dst [get_property ENDPOINT_PIN $p]
    puts [format "Slack: %7.3f ns | From: %-60s | To: %s" $slk $src $dst]
}
exit
