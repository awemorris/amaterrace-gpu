open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
foreach n {
    setup/fm_a_lo[15]_i_16_n_0
    setup/fm_b_lo[15]_i_18_n_0
    setup/fa_b_lo[15]_i_5_n_0
    setup/b_m_lo[0]
    setup/b_o_lo[0]
    setup/fd_v
    setup/r_bcl_sign_hi_i_1_n_0
    setup/u_lw_fix/s_coarse2_hi1
    setup/u_ps_fix/s_coarse2_hi1
    setup_n_503
    setup_n_504
} {
    set net [get_nets -quiet $n]
    if {$net != ""} {
        puts "=== Net: $net (Fanout: [get_property FLAT_PIN_COUNT $net]) ==="
        set pins [get_pins -leaf -of_objects $net]
        puts "  Total pins: [llength $pins]"
        # print first 10 pins
        for {set i 0} {$i < [expr {[llength $pins] < 10 ? [llength $pins] : 10}]} {incr i} {
            puts "    [lindex $pins $i]"
        }
    }
}
exit
