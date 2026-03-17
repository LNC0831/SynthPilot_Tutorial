module sampler_uart_top #(
    parameter DATA_WIDTH   = 8,
    parameter BAUD_RATE    = 115200,
    parameter CLK_SYS_FREQ = 50_000_000,
    parameter SAMPLE_DIV   = 20000
)(
    input  wire clk_fast,
    input  wire clk_sys,
    input  wire rst_n,
    output wire tx_out,
    output wire fifo_full,
    output wire fifo_empty
);

    // Internal signals
    wire [DATA_WIDTH-1:0] sample_data;
    wire                  sample_valid;
    wire                  fifo_full_w;
    wire                  fifo_empty_w;
    wire [DATA_WIDTH-1:0] fifo_dout;
    wire                  wr_rst_busy;
    wire                  rd_rst_busy;
    wire                  tx_ready;

    // FIFO write/read enable with rst_busy protection
    wire fifo_wr_en = sample_valid & ~wr_rst_busy;
    wire fifo_rd_en = tx_ready & ~fifo_empty_w & ~rd_rst_busy;

    // Debug outputs
    assign fifo_full  = fifo_full_w;
    assign fifo_empty = fifo_empty_w;

    // Data sampler instance (200 MHz domain)
    data_sampler #(
        .DATA_WIDTH (DATA_WIDTH),
        .SAMPLE_DIV (SAMPLE_DIV)
    ) u_data_sampler (
        .clk        (clk_fast),
        .rst_n      (rst_n),
        .data_out   (sample_data),
        .data_valid (sample_valid),
        .fifo_full  (fifo_full_w | wr_rst_busy)
    );

    // Async FIFO instance (Xilinx IP, rst is active-high)
    async_fifo u_async_fifo (
        .rst        (~rst_n),
        .wr_clk     (clk_fast),
        .rd_clk     (clk_sys),
        .din        (sample_data),
        .wr_en      (fifo_wr_en),
        .rd_en      (fifo_rd_en),
        .dout       (fifo_dout),
        .full       (fifo_full_w),
        .empty      (fifo_empty_w),
        .wr_rst_busy(wr_rst_busy),
        .rd_rst_busy(rd_rst_busy)
    );

    // UART TX instance (50 MHz domain)
    uart_tx #(
        .CLK_FREQ  (CLK_SYS_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart_tx (
        .clk       (clk_sys),
        .rst_n     (rst_n),
        .tx_data   (fifo_dout),
        .tx_valid  (~fifo_empty_w & ~rd_rst_busy),
        .tx_ready  (tx_ready),
        .tx_out    (tx_out)
    );

endmodule
