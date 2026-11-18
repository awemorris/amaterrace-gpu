set top "atg_cp"
set clk_period 4.000
set part xc7k325tffg900-2
set root [file normalize [file join [file dirname [info script]] ".."]]
set incdirs [list [file join $root include]]

set v_files [glob -nocomplain [file join $root rtl library * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl library *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu cp *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu fmt *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu atg_cp.v]]

set unique_files [lsort -unique $v_files]
foreach f $unique_files {
    read_verilog $f
}

synth_design -top $top -part $part -mode out_of_context -include_dirs $incdirs -verilog_define [list "SYNTH_KINTEX7"]

set mem_cells [get_cells -hierarchical -filter {
    REF_NAME =~ "RAMB*" || REF_NAME =~ "RAM32*" || REF_NAME =~ "RAM64*" || REF_NAME =~ "RAM128*"
}]
puts "=== MEM_CELLS WITH DISTRIBUTED RAM: [llength $mem_cells] ==="
foreach m $mem_cells { puts $m }
