open_checkpoint build/asic_lint/atg_blt/post_synth.dcp

set viol_nets [list "b2d/ce_clip_raw" "b2d/ce_start_raw" "b2d/ce_init_raw" "b2d/p_0_in176_in" "b2d/FSM_onehot_state_reg_n_0_[6]" "b2d/p_0_in10_in"]

foreach vn $viol_nets {
    puts "=================================================="
    puts "NET: $vn"
    set n [get_nets -quiet $vn]
    if {$n != ""} {
        puts "Driver: [get_pins -of_objects $n -filter {DIRECTION == OUT}]"
        set loads [get_pins -of_objects $n -filter {DIRECTION == IN}]
        puts "Load count: [llength $loads]"
        puts "Loads (first 10): [lrange $loads 0 9]"
    } else {
        puts "Not found"
    }
}
exit 0
