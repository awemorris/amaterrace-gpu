open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set p [get_timing_paths -to [get_pins u_seq/st_reg[0]/D] -max_paths 1]
puts "Timing path to u_seq/st_reg[0]/D:"
puts "  Slack: [get_property SLACK $p]"
puts "  Levels: [get_property LOGIC_LEVELS $p]"
foreach pin [get_pins -of_objects $p] {
    puts "  $pin"
}
