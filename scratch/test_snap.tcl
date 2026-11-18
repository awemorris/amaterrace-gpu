open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set n [get_nets setup/edge_u/u_snap_sh/g_snap_reg[2].r_snap_shifted[47]_i_2_n_0]
puts "NAME: [get_property NAME $n]"
puts "PIN_COUNT: [get_property FLAT_PIN_COUNT $n]"
set driver [get_pins -leaf -of_objects $n -filter {DIRECTION == OUT}]
puts "DRIVER: $driver ([get_property REF_NAME [get_cells -of_objects $driver]])"
set pins [get_pins -leaf -of_objects $n -filter {DIRECTION == IN}]
puts "NUM PINS: [llength $pins]"
puts "LOAD PINS: [lrange $pins 0 10]"
exit
