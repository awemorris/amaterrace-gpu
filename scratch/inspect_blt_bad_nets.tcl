open_checkpoint build/asic_lint/atg_blt/post_synth.dcp

set bad_nets [list "b2d/m_dtile_i_1_n_0" "b2d/u_sgo_i_1_n_0" "b2d/req_write_INST_0_i_1_n_0" "b2d/a_da_n_8" "b2d/a_sa_n_12" "b2d/sy0[0]" "b2d/p_dline[0]" "b2d/seg_line[0]" "b2d/da[0]" "b2d/snu[0]" "b2d/seg_last" "b2d/bst_seg_last" "b2d/bst_req_write" "b2d/g_da_full[0]"]

foreach n $bad_nets {
    set net_obj [get_nets -quiet $n]
    if {$net_obj != ""} {
        set fo [get_property FLAT_PIN_COUNT $net_obj]
        set drv [get_cells -of_objects [get_pins -of_objects $net_obj -filter {DIRECTION == "OUT"}]]
        puts "NET $n (FO: $fo): driver cell '$drv'"
        set load_cells [get_cells -of_objects [get_pins -of_objects $net_obj -filter {DIRECTION == "IN"}]]
        puts "  first 5 loads: [lrange $load_cells 0 4]"
    } else {
        puts "NET $n NOT FOUND"
    }
}
exit
