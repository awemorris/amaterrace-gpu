open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set p [get_pins u_ring/out]
set n [get_nets -of_objects $p]
puts "net connected to u_ring/out: $n"
set drv [get_pins -of_objects $n -filter {DIRECTION == OUT}]
puts "driver pin: $drv"
