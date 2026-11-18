set port_net [get_nets -of_objects [get_ports rst_n]]
puts "Port rst_n net: $port_net"
puts "Top net of hierarchical group: [get_nets -top_net_of_hierarchical_group -of_objects $port_net]"
exit
