open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
proc check_net {net_name} {
    set n [get_nets -quiet $net_name]
    if {$n != ""} {
        puts "LOADS OF $net_name: [get_property FLAT_PIN_COUNT $n]"
        foreach p [get_pins -leaf -of_objects $n] {
            puts "  pin: $p"
        }
    } else {
        puts "NET $net_name NOT FOUND"
    }
}
check_net "b2d/ce_clip_raw"
check_net "b2d/ce_ydl_init"
check_net "b2d/seg_p0_reg_n_0_[2]"
check_net "b2d/seg_p0_reg_n_0_[3]"
check_net "b2d/seg_p0_reg_n_0_[4]"
check_net "b2d/seg_p0_reg_n_0_[1]"
exit 0
