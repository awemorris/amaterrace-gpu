open_checkpoint build/asic_lint/atg_rop/post_synth.dcp
set n [get_nets p_0_in]
puts "NAME: [get_property NAME $n]"
set drv [get_pins -leaf -of_objects $n -filter {DIRECTION == OUT}]
puts "DRIVER: $drv"
set cells [get_cells -of_objects $drv]
puts "DRIVER CELL: $cells [get_property REF_NAME $cells]"
