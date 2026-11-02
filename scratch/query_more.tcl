open_checkpoint build/asic_lint/atg_su/post_synth.dcp
proc report_net_info {net_name} {
    set n [get_nets -quiet $net_name]
    if {[llength $n] == 0} {
        puts "Net $net_name not found"
        return
    }
    set driver [get_pins -quiet -leaf -of_objects $n -filter {DIRECTION == OUT}]
    set loads [get_pins -quiet -leaf -of_objects $n -filter {DIRECTION == IN}]
    puts "=== Net: $net_name (driver: $driver, load_count: [llength $loads]) ==="
    set count 0
    foreach p $loads {
        puts "  Load: $p"
        incr count
        if {$count >= 8} {
            puts "  ... and [expr {[llength $loads] - 8}] more"
            break
        }
    }
}
report_net_info "exp/has_src1[3]_i_2_n_0"
report_net_info "exp/drain/d_warp[0]_i_4_n_0"
report_net_info "exp/drain/st[0]_i_5_n_0"
report_net_info "exp/drain/d_q[2]_i_3_n_0"
report_net_info "exp/drain/d_rt[2]_i_3_n_0"
exit
