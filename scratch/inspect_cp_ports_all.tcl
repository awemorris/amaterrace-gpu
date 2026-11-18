open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set in_ports [get_ports -filter {DIRECTION == "IN" && NAME !~ "*clk*" && NAME !~ "*rst*" && NAME !~ "*reset*"}]
puts "Input ports fanouts:"
foreach p $in_ports {
    set n [get_nets -hierarchical -top_net_of_hierarchical_group -filter "NAME == $p"]
    if {$n != ""} {
        set pc [get_property FLAT_PIN_COUNT $n]
        set fo [expr {$pc - 1}]
        if {$fo > 24} {
            puts "  Port: $p (FO: $fo)"
        }
    }
}
