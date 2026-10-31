open_checkpoint build/asic_lint/atg_rop/post_synth.dcp
set n [get_nets wb/wpix/g_fblend.fblend/f_bl[2]]
set pins [get_pins -leaf -of_objects $n -filter {DIRECTION == IN}]
puts "PIN COUNT: [llength $pins]"
puts "SAMPLE PINS (first 10):"
foreach p [lrange $pins 0 9] {
    puts "  $p (REF_PIN: [get_property REF_PIN_NAME $p], CELL: [get_property REF_NAME [get_cells -of_objects $p]])"
}
