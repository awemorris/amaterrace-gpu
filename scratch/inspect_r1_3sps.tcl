open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
puts "=== 1. reg_waddr[15] ==="
set p [get_timing_paths -from [get_ports reg_waddr[15]] -max_paths 1]
puts "To: [get_property ENDPOINT_PIN $p] | Slack: [get_property SLACK $p] | Levels: [get_property LOGIC_LEVELS $p]"
foreach pin [get_pins -of_objects $p] {
    puts "  pin: $pin"
}

puts "=== 2. u_ring/hdr_data_reg[6]/C ==="
set p [get_timing_paths -from [get_pins u_ring/hdr_data_reg[6]/C] -max_paths 1]
puts "To: [get_property ENDPOINT_PIN $p] | Slack: [get_property SLACK $p] | Levels: [get_property LOGIC_LEVELS $p]"
foreach pin [get_pins -of_objects $p] {
    puts "  pin: $pin"
}

puts "=== 3. u_skid_ring_seq/out_data_reg[7]/C ==="
set p [get_timing_paths -from [get_pins u_skid_ring_seq/out_data_reg[7]/C] -max_paths 1]
puts "To: [get_property ENDPOINT_PIN $p] | Slack: [get_property SLACK $p] | Levels: [get_property LOGIC_LEVELS $p]"
foreach pin [get_pins -of_objects $p] {
    puts "  pin: $pin"
}
