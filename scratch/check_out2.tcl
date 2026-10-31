
set part xc7k325tffg900-2
set incdirs [list [file normalize "include"]]
set v_files [glob -nocomplain rtl/library/*/*.v rtl/library/*.v rtl/gpu/blt/*.v rtl/gpu/fmt/*.v rtl/gpu/atg_blt.v]
foreach f [lsort -unique $v_files] { read_verilog $f }
synth_design -top atg_blt -part $part -mode out_of_context -include_dirs $incdirs -verilog_define SYNTH_KINTEX7
set n [get_nets b2d/port/out]
puts "NAME: [get_property NAME $n]"
puts "PARENT_CELL: [get_property -quiet PARENT_CELL $n]"
puts "FLAT_PIN_COUNT: [get_property FLAT_PIN_COUNT $n]"
set leaf_drv [get_pins -leaf -filter {DIRECTION == OUT} -of_objects $n]
puts "LEAF DRIVER: $leaf_drv"
puts "LEAF DRIVER CELL: [get_cells -of_objects $leaf_drv]"
puts "LEAF DRIVER CELL TYPE: [get_property REF_NAME [get_cells -of_objects $leaf_drv]]"
