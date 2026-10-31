open_checkpoint build/asic_lint/atg_blt/post_synth.dcp
set nets [list \
    "b2d/m_keep[3]_i_1_n_0" \
    "b2d/mr_buf[23]" \
    "b2d/mr_buf[30]" \
    "b2d/px_b[15]_i_6_n_0" \
    "b2d/d_xb_b_inferred_i_26_n_0" \
    "b2d/d_xb_b_inferred_i_28_n_0" \
    "b2d/p_152_in" \
    "b2d/cur_b_dst_delta_lo[4]_i_1_n_0" \
    "b2d/r_dst_delta_norm[31]_i_1_n_0" \
    "b2d/g_ce_sm[2].u_sm_i_1_n_0" \
]

foreach net_name $nets {
    set n [get_nets -hierarchical -quiet "*$net_name*"]
    puts "=================================================="
    puts "NET: $net_name (found: $n)"
    if {$n != ""} {
        set drv [get_pins -of_objects $n -filter {DIRECTION == OUT}]
        puts "DRIVER: $drv"
        set lds [get_pins -of_objects $n -filter {DIRECTION == IN}]
        puts "LOAD COUNT: [llength $lds]"
        puts "FIRST 5 LOADS: [lrange $lds 0 4]"
    }
}
