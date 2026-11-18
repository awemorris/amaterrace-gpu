set n [get_nets -quiet "g_cursor.cursor/g_ff_slice[9].ff_slice_reg_0_3_12_15/DID0"]
if {$n != ""} {
    puts "IS_CONSTANT: [get_property IS_CONSTANT $n]"
}
exit
