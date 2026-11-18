open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set n [get_nets "setup/st_reg[2]_rep__3_n_0"]
puts "NET: $n"
if {[llength $n] > 0} {
    set loads [get_pins -filter {DIRECTION == IN} -leaf -of_objects $n]
    puts "LOAD COUNT: [llength $loads]"
    foreach l [lrange $loads 0 15] {
        puts "  LOAD: $l (CELL: [get_property REF_NAME [get_cells -of_objects $l]])"
    }
}
