set rpt [open "scratch/net_report.txt" "w"]
set nets [list sync_line_n_12 p_0_in_0 in00_1]
foreach n_name $nets {
    set n [get_nets -quiet $n_name]
    if {$n != ""} {
        set drv [get_pins -quiet -of_objects $n -filter {DIRECTION == "OUT"}]
        set lds [get_pins -quiet -of_objects $n -filter {DIRECTION == "IN"}]
        puts $rpt "NET: $n_name (count [llength $lds])"
        puts $rpt "  DRIVER: $drv"
        puts $rpt "  SAMPLE LOADS:"
        for {set i 0} {$i < 10 && $i < [llength $lds]} {incr i} {
            puts $rpt "    [lindex $lds $i]"
        }
    } else {
        puts $rpt "NET: $n_name NOT FOUND"
    }
}
close $rpt
exit
