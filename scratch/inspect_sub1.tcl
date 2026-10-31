open_checkpoint build/asic_lint/atg_rop_sub1/post_synth.dcp
foreach net_name {*u_sum_n_28* *u_sum_n_29* *u_sum_n_30* *lz_hi_4* *dsh_hi_0* *dsh_hi_2* *ea_xle[7]*} {
    set n [get_nets -hierarchical $net_name]
    if {$n != ""} {
        puts "Net: $n, Fanout: [get_property FLAT_PIN_COUNT $n]"
        set d [get_pins -of_objects $n -filter {DIRECTION == "OUT"}]
        puts "Driver pin: $d"
        set c [get_cells -of_objects $d]
        puts "Driver cell: $c, REF: [get_property REF_NAME $c]"
    }
}
exit
