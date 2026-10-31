open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set top_paths [get_timing_paths -max_paths 100 -nworst 1 -setup]
set startpoints [list]
foreach p $top_paths {
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN $p]
    lappend startpoints "$sp --> [get_property REF_NAME [get_cells -of_objects $ep]]"
}
set u_sps [lsort -unique $startpoints]
foreach s $u_sps {
    puts "Startpoint group: $s"
}
