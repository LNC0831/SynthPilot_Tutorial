# ==============================================================================
# top.xdc — XDMA + FFT Spectrum Analyzer constraints
# Target: xcku3p-ffvb676-2-e
# ==============================================================================

# ------------------------------------------------------------------------------
# System Clock (100 MHz differential -> Clock Wizard input)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN E18 [get_ports sys_clk_p]
set_property PACKAGE_PIN D18 [get_ports sys_clk_n]
set_property IOSTANDARD LVDS [get_ports sys_clk_p]
set_property IOSTANDARD LVDS [get_ports sys_clk_n]

create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]

# ------------------------------------------------------------------------------
# PCIe Reference Clock (100 MHz GT refclk, no IOSTANDARD needed)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN T7 [get_ports pcie_refclk_p]

create_clock -period 10.000 -name pcie_refclk [get_ports pcie_refclk_p]

# ------------------------------------------------------------------------------
# PCIe GT TX Lanes (LOC only, Vivado infers N-side)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN R5  [get_ports {pcie_txp[0]}]
set_property PACKAGE_PIN U5  [get_ports {pcie_txp[1]}]
set_property PACKAGE_PIN W5  [get_ports {pcie_txp[2]}]
set_property PACKAGE_PIN AA5 [get_ports {pcie_txp[3]}]

# ------------------------------------------------------------------------------
# PCIe Reset (active-low)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN A9 [get_ports pcie_perstn]
set_property IOSTANDARD LVCMOS18 [get_ports pcie_perstn]
set_property PULLUP true [get_ports pcie_perstn]

# ------------------------------------------------------------------------------
# LED (link-up indicator, active-low)
# ------------------------------------------------------------------------------
set_property PACKAGE_PIN B12 [get_ports led_link_up]
set_property IOSTANDARD LVCMOS18 [get_ports led_link_up]

# ------------------------------------------------------------------------------
# False paths
# ------------------------------------------------------------------------------
# PCIe reset is asynchronous
set_false_path -from [get_ports pcie_perstn]

# LED is a slow status output, no timing requirement
set_false_path -to [get_ports led_link_up]
