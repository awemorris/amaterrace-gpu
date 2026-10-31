open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set in_ports [get_ports -filter {DIRECTION == "IN"}]
set out_ports [get_ports -filter {DIRECTION == "OUT"}]
puts "=== ALL RULE 3 FEEDTHROUGH PATHS ==="
set fps [get_timing_paths -from $in_ports -to $out_ports -max_paths 100]
foreach fp $fps {
    set sp [get_property STARTPOINT_PIN $fp]
    set ep [get_property ENDPOINT_PIN $fp]
    set lev [get_property LOGIC_LEVELS $fp]
    puts "Feedthrough: $sp -> $ep ($lev levels)"
}
