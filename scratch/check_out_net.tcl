
set part xc7k325tffg900-2
set incdirs [list [file normalize "include"]]
set v_files [glob -nocomplain rtl/library/*/*.v rtl/library/*.v rtl/gpu/blt/*.v rtl/gpu/fmt/*.v rtl/gpu/atg_blt.v]
foreach f [lsort -unique $v_files] { read_verilog $f }
synth_design -top atg_blt -part $part -mode out_of_context -include_dirs $incdirs -verilog_define SYNTH_KINTEX7
puts "=== Net b2d/cfg/out pins ==="
catch {
    set n [get_nets b2d/cfg/out]
    puts "Net: $n"
    puts "Driver: [get_pins -quiet -of_objects $n -filter {DIRECTION == OUT}]"
    set pins [get_pins -quiet -of_objects $n]
    puts "Pin count: [llength $pins]"
    puts "First 10 pins: [lrange $pins 0 9]"
}
puts "=== Net b2d/port/out pins ==="
catch {
    set n [get_nets b2d/port/out]
    puts "Net: $n"
    puts "Driver: [get_pins -quiet -of_objects $n -filter {DIRECTION == OUT}]"
    set pins [get_pins -quiet -of_objects $n]
    puts "Pin count: [llength $pins]"
    puts "First 10 pins: [lrange $pins 0 9]"
}
