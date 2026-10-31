open_checkpoint build/asic_lint/atg_rx/post_synth.dcp
set nets [list "setup/fm_a_lo[15]_i_16_n_0" "setup/fa_b_lo[14]_i_3_n_0" "scan/cov_reg_scov[3]_i_2_n_0"]
foreach n $nets {
    set net [get_nets -quiet $n]
    if {$net != ""} {
        puts "=== NET: $n (fanout: [get_property FLAT_PIN_COUNT $net]) ==="
        set drv [get_pins -of_objects $net -filter {DIRECTION == "OUT"}]
        puts "  Driver: $drv ([get_property REF_NAME [get_cells -of_objects $drv]])"
        set loads [get_pins -of_objects $net -filter {DIRECTION == "IN"}]
        puts "  Loads count: [llength $loads]"
        foreach l [lrange $loads 0 10] {
            puts "    load: $l ([get_property REF_NAME [get_cells -of_objects $l]])"
        }
    }
}
exit
