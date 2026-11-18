open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set paths [get_timing_paths -max_paths 50]
puts "=== TOP 20 TIMING PATHS ON CURRENT CP ==="
set count 0
foreach p $paths {
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN $p]
    set lev [get_property LOGIC_LEVELS $p]
    puts "Path $count: Levels=$lev : $sp -> $ep"
    incr count
    if {$count >= 20} break
}
