open_checkpoint build/asic_lint/atg_blt/post_synth.dcp

set r1_viols [list]
# Find timing paths with logic levels > 4
set paths [get_timing_paths -max_paths 100 -nworst 1]
foreach p $paths {
    set lev [get_property LOGIC_LEVELS $p]
    if {$lev > 4} {
        set sp [get_property STARTPOINT_PIN $p]
        set ep [get_property ENDPOINT_PIN $p]
        puts "LEV $lev: $sp --> $ep"
    }
}
exit 0
