open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set n [get_nets -hier *u_amb_n_65*]
puts "NET: $n"
set drv [get_pins -of_objects $n -filter {DIRECTION == OUT}]
puts "DRV: $drv ([get_property REF_NAME [get_cells -of_objects $drv]])"
puts "CONSUMERS: [get_pins -of_objects $n -filter {DIRECTION == IN}]"
