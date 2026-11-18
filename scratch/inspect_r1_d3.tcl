open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set paths [get_timing_paths -max_paths 50]
puts "=== TOP 20 TIMING PATHS BY LOGIC LEVEL ==="
set count 0
foreach p $paths {
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN $p]
    set lev [get_property LOGIC_LEVELS $p]
    set wns [get_property SLACK $p]
    puts "Path $count: Levels=$lev Slack=$wns : $sp -> $ep"
    incr count
    if {$count >= 20} break
}
