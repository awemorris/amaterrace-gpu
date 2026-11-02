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
    # Show first 15 loads
    set count 0
    foreach p $loads {
        puts "  Load: $p"
        incr count
        if {$count >= 15} {
            puts "  ... and [expr {[llength $loads] - 15}] more"
            break
        }
    }
}

report_net_info "exp/dw_rtw[0]"
report_net_info "exp/dqs_y[2]"
report_net_info "exp/dq[2]"
report_net_info "exp/drain_n_98"
report_net_info "exp/drain_n_90"
report_net_info "exp/drain_n_88"
report_net_info "exp/drain_n_87"
report_net_info "exp/drain_n_160"

exit
