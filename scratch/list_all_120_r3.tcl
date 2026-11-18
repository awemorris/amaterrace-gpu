open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set in_ports [get_ports -filter {DIRECTION == "IN"}]
set out_ports [get_ports -filter {DIRECTION == "OUT"}]
set fps [get_timing_paths -from $in_ports -to $out_ports -max_paths 1000]
puts "=== LIST OF ALL [llength $fps] COMBINATIONAL FEEDTHROUGHS ==="
set idx 0
foreach fp $fps {
    set sp [get_property STARTPOINT_PIN $fp]
    set ep [get_property ENDPOINT_PIN $fp]
    set lev [get_property LOGIC_LEVELS $fp]
    puts "$idx: $sp -> $ep ($lev levels)"
    incr idx
}
