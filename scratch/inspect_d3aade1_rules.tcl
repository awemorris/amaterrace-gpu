open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set in_ports [get_ports -filter {DIRECTION == "IN"}]
set out_ports [get_ports -filter {DIRECTION == "OUT"}]
puts "=== FEEDTHROUGH PATHS ==="
set fps [get_timing_paths -from $in_ports -to $out_ports -max_paths 10]
foreach fp $fps {
    puts "[get_property STARTPOINT_PIN $fp] -> [get_property ENDPOINT_PIN $fp] ([get_property LOGIC_LEVELS $fp])"
}
