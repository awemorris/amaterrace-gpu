open_checkpoint build/asic_lint/atg_cp/post_synth.dcp
set internal_nets [get_nets -hierarchical -top_net_of_hierarchical_group -filter {
    TYPE != "GLOBAL_CLOCK" && TYPE != "LOCAL_CLOCK" && TYPE != "GROUND" && TYPE != "POWER" &&
    NAME !~ "*clk*" && NAME !~ "*rst*" && NAME !~ "*reset*" &&
    NAME !~ "*<const*" && NAME !~ "*GND*" && NAME !~ "*VCC*" && NAME !~ "*GLOBAL_LOGIC*"
}]
set hfo_list [list]
foreach n $internal_nets {
    set fo [expr {[get_property PIN_COUNT $n] - 1}]
    if {$fo > 24} {
        lappend hfo_list [list $fo $n [get_pins -quiet -of_objects $n -filter {DIRECTION == "OUT"}]]
    }
}
set hfo_sorted [lsort -integer -decreasing -index 0 $hfo_list]
puts "=== TOP 40 HARD FANOUT NETS (COUNT: [llength $hfo_sorted]) ==="
set idx 0
foreach item $hfo_sorted {
    puts "FO=[lindex $item 0] : [lindex $item 1] (driver: [lindex $item 2])"
    incr idx
    if {$idx >= 40} break
}
