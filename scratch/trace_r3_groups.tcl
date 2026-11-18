open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set in_ports [get_ports -filter {DIRECTION == "IN"}]
set out_ports [get_ports -filter {DIRECTION == "OUT"}]
set fps [get_timing_paths -from $in_ports -to $out_ports -max_paths 200]
puts "=== UNIQUE FEEDTHROUGH (STARTPOINT -> ENDPOINT) [llength $fps] paths ==="
set pairs [list]
foreach fp $fps {
    set sp [get_property STARTPOINT_PIN $fp]
    set ep [get_property ENDPOINT_PIN $fp]
    set sp_bus [regsub {\[[0-9]+\]} $sp ""]
    set ep_bus [regsub {\[[0-9]+\]} $ep ""]
    lappend pairs "$sp_bus -> $ep_bus"
}
puts "Unique bus feedthroughs:"
foreach u [lsort -unique $pairs] {
    puts "  $u"
}
