module data_sampler #(
    parameter DATA_WIDTH  = 8,
    parameter SAMPLE_DIV  = 20000
)(
    input  wire                  clk,
    input  wire                  rst_n,
    output wire [DATA_WIDTH-1:0] data_out,
    output reg                   data_valid,
    input  wire                  fifo_full
);

    // Division counter width
    localparam DIV_WIDTH = $clog2(SAMPLE_DIV);

    reg [DIV_WIDTH-1:0] div_cnt;
    wire                sample_tick;
    reg [DATA_WIDTH-1:0] data_cnt;

    // Division counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            div_cnt <= {DIV_WIDTH{1'b0}};
        else if (div_cnt == SAMPLE_DIV - 1)
            div_cnt <= {DIV_WIDTH{1'b0}};
        else
            div_cnt <= div_cnt + 1'b1;
    end

    assign sample_tick = (div_cnt == SAMPLE_DIV - 1);

    // Data valid — one cycle pulse
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            data_valid <= 1'b0;
        else
            data_valid <= sample_tick & ~fifo_full;
    end

    // Data counter — increment after data_valid (value already captured by FIFO)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            data_cnt <= {DATA_WIDTH{1'b0}};
        else if (data_valid)
            data_cnt <= data_cnt + 1'b1;
    end

    // Combinational output — current counter value available when data_valid is high
    assign data_out = data_cnt;

endmodule
