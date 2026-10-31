open_checkpoint build/asic_lint/atg_blt/post_synth.dcp

set bad_nets {
    "b2d/line_pixels_b[5]_i_1_n_0"
    "b2d/issue_fire"
    "b2d/snu[0]"
    "b2d/g_sa_full[31]_i_1_n_0"
    "b2d/fail_fsm"
    "b2d/bw_bank_reg_n_0"
    "b2d/da[0]"
    "b2d/bst_req_write"
    "b2d/a_sa_n_8"
    "b2d/a_da_n_12"
    "b2d/wr_go"
    "b2d/seg_line[0]"
    "b2d/bw_slot_cnt[0]"
    "b2d/ysl_b[1]_i_1_n_0"
    "b2d/ydl_b_reg_n_0_[1]"
    "b2d/rem[16]_i_1_n_0"
    "b2d/m_copy_i_1_n_0"
    "b2d/sy0[0]"
    "b2d/req_valid_INST_0_i_2_n_0"
    "b2d/seg_last"
    "b2d/m_dtile_i_1_n_0"
    "b2d/spx_row[16]_i_1_n_0"
}

foreach net_name $bad_nets {
    set net [get_nets -quiet $net_name]
    if {$net != ""} {
        set driver [get_pins -quiet -of_objects $net -filter {DIRECTION == "OUT"}]
        set num_pins [llength [get_pins -of_objects $net]]
        puts "=== NET: $net_name (total pins: $num_pins) ==="
        puts "  DRIVER: $driver"
        set sample_pins [lrange [get_pins -of_objects $net -filter {DIRECTION == "IN"}] 0 5]
        foreach p $sample_pins {
            puts "  LOAD: $p"
        }
    }
}
