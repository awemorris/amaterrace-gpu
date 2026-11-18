open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
puts "=== PARENT OF U_AMB ==="
puts [get_property PARENT [get_cells u_amb]]
puts "=== U_AMB CELLS ==="
puts [get_cells -filter {PARENT == "u_amb"}]
