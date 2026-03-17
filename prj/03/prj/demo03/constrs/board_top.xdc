## Clock
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]

## Pin assignments
# 50 MHz system clock
set_property PACKAGE_PIN K17 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]

# Active-low reset button
set_property PACKAGE_PIN M20 [get_ports sys_rst_n]
set_property IOSTANDARD LVCMOS33 [get_ports sys_rst_n]

# UART TX
set_property PACKAGE_PIN P15 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]

# LED - PLL locked indicator
set_property PACKAGE_PIN T12 [get_ports led]
set_property IOSTANDARD LVCMOS33 [get_ports led]
