open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set n [get_nets u_ring/out]
puts "driver of u_ring/out: [get_pins -of_objects $n -filter {DIRECTION == OUT}]"
