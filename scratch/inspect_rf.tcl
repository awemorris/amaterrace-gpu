open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set internal_nets [get_nets -hierarchical -top_net_of_hierarchical_group -filter {
    TYPE != "GLOBAL_CLOCK" && TYPE != "LOCAL_CLOCK" && TYPE != "GROUND" && TYPE != "POWER" &&
    NAME !~ "*clk*" && NAME !~ "*rst*" && NAME !~ "*reset*" &&
    NAME !~ "*<const*" && NAME !~ "*GND*" && NAME !~ "*VCC*" && NAME !~ "*GLOBAL_LOGIC*"
}]
set fo_list [list]
foreach n $internal_nets {
    set pin_cnt [get_property FLAT_PIN_COUNT $n]
    set fo [expr {$pin_cnt - 1}]
    if {$fo > 24} {
        set drv [get_pins -quiet -of_objects $n -filter {DIRECTION == "OUT"}]
        lappend fo_list [list $fo $n $drv]
    }
}
set sorted [lsort -integer -decr -index 0 $fo_list]
puts "Top 30 High Fanout Nets:"
for {set i 0} {$i < [llength $sorted] && $i < 30} {incr i} {
    set item [lindex $sorted $i]
    puts "FO: [lindex $item 0] | Net: [lindex $item 1] | Driver: [lindex $item 2]"
}
