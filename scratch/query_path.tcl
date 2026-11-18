open_checkpoint build/asic_lint/atg_su/post_synth.dcp
set p [get_timing_paths -from [get_cells opd/b_uop_reg[60]] -max_paths 1]
puts "PATH: $p"
puts "LEVELS: [get_property LOGIC_LEVELS $p]"
foreach pin [get_pins -of_objects $p] {
    puts "  PIN: $pin ([get_property CELL_NAME [get_cells -of_objects $pin]])"
}
