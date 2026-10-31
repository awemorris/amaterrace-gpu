open_checkpoint build/asic_lint/atg_tu/post_synth.dcp
set mems [get_cells -hierarchical -filter {REF_NAME =~ "RAM*"}]
puts "Total RAM cells: [llength $mems]"

# Group by parent module
set counts [dict create]
foreach m $mems {
    set p [get_property PARENT $m]
    if {[dict exists $counts $p]} {
        dict incr counts $p
    } else {
        dict set counts $p 1
    }
}
dict for {p c} $counts {
    puts "  $p: $c"
}
