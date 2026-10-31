set top "atg_top"
set root [file normalize [file join [file dirname [info script]] ".."]]
set incdirs [list [file join $root include]]

set v_files [glob -nocomplain [file join $root rtl library * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl library *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl gpu *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl bsp * *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl bsp *.v]]
lappend v_files {*}[glob -nocomplain [file join $root rtl *.v]]

set unique_files [lsort -unique $v_files]
puts "Total files: [llength $unique_files]"
