set rpt [open "scratch/net_report.txt" "w"]
set n1 [get_nets -quiet "p_0_in_0"]
if {$n1 != ""} {
    puts $rpt "p_0_in_0 driver: [get_pins -of $n1 -filter {DIRECTION == OUT}]"
    puts $rpt "p_0_in_0 loads: [get_pins -of $n1 -filter {DIRECTION == IN} -range 0 5]"
}
set n2 [get_nets -quiet "in00_1"]
if {$n2 != ""} {
    puts $rpt "in00_1 driver: [get_pins -of $n2 -filter {DIRECTION == OUT}]"
    puts $rpt "in00_1 loads: [get_pins -of $n2 -filter {DIRECTION == IN} -range 0 5]"
}
close $rpt
exit
