open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
foreach nname [list "scan/g_zv_slices[1].zv[29]_i_2_n_0" "scan/g_xy_slices[1].dx_xy[31]_i_2_n_0" "scan/g_coarse.u_coarse/bx0[0]" "scan/g_coarse.u_coarse/st_reg_n_0_[2]"] {
    set n [get_nets $nname]
    puts "NET: $nname, fanout: [get_property FLAT_PIN_COUNT $n]"
    puts "DRIVER: [get_pins -leaf -of_objects $n -filter {DIRECTION == "OUT"}]"
    set pins [get_pins -leaf -of_objects $n -filter {DIRECTION == "IN"}]
    foreach p [lrange $pins 0 5] {
        puts "  PIN: $p"
    }
}
exit
