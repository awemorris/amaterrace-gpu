open_checkpoint build/asic_lint/atg_rx/post_synth.dcp

set internal_nets [get_nets -hierarchical -top_net_of_hierarchical_group -filter {
    TYPE != "GLOBAL_CLOCK" && TYPE != "LOCAL_CLOCK" && TYPE != "GROUND" && TYPE != "POWER" &&
    NAME !~ "*clk*" && NAME !~ "*rst*" && NAME !~ "*reset*" &&
    NAME !~ "*<const*" && NAME !~ "*GND*" && NAME !~ "*VCC*" && NAME !~ "*GLOBAL_LOGIC*"
}]

set viols [list]
foreach n $internal_nets {
    set fo [expr {[get_property FLAT_PIN_COUNT $n] - 1}]
    if {$fo > 24} {
        lappend viols [list $fo [get_property NAME $n]]
    }
}

set sorted [lsort -decreasing -integer -index 0 $viols]
puts "=== TOP 30 FANOUT VIOLATIONS IN ATG_RX ==="
set count 0
foreach v $sorted {
    if {$count < 30} {
        set fo [lindex $v 0]
        set name [lindex $v 1]
        set driver [get_pins -leaf -of_objects [get_nets $name] -filter {DIRECTION == OUT}]
        set dcell ""
        if {[llength $driver] > 0} {
            set dcell [get_property REF_NAME [get_cells -of_objects $driver]]
        }
        puts [format "%5d  %-40s  driver: %s (%s)" $fo $name $driver $dcell]
        incr count
    }
}
puts "TOTAL VIOLATIONS: [llength $sorted]"
exit
