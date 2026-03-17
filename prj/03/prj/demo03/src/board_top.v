`timescale 1ns / 1ps

module board_top (
    input  wire sys_clk,      // 50 MHz board clock (K17)
    input  wire sys_rst_n,    // Active-low reset button (M20)
    output wire uart_tx,      // UART TX output (P15)
    output wire led           // PLL locked indicator (T12)
);

    // Internal signals
    wire clk_fast;    // 200 MHz from clk_wiz_0
    wire clk_sys;     // 50 MHz from clk_wiz_0
    wire locked;      // PLL locked signal

    // Combined reset: locked AND external reset
    wire rst_n = locked & sys_rst_n;

    // LED indicates PLL lock status
    assign led = locked;

    // Clocking Wizard IP instance
    clk_wiz_0 u_clk_wiz (
        .clk_in1  (sys_clk),
        .reset    (~sys_rst_n),   // Active-high reset
        .clk_out1 (clk_fast),    // 200 MHz
        .clk_out2 (clk_sys),     // 50 MHz
        .locked   (locked)
    );

    // Multi-clock domain data acquisition & UART output
    sampler_uart_top u_sampler_uart_top (
        .clk_fast   (clk_fast),
        .clk_sys    (clk_sys),
        .rst_n      (rst_n),
        .tx_out     (uart_tx),
        .fifo_full  (),           // Not connected at board level
        .fifo_empty ()            // Not connected at board level
    );

endmodule
