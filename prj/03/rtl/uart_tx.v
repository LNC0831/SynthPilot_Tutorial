module uart_tx #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] tx_data,
    input  wire       tx_valid,
    output reg        tx_ready,
    output reg        tx_out
);

    localparam BAUD_DIV = CLK_FREQ / BAUD_RATE;
    localparam DIV_WIDTH = $clog2(BAUD_DIV);

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]          state;
    reg [DIV_WIDTH-1:0] baud_cnt;
    reg [2:0]          bit_idx;
    reg [7:0]          shift_reg;
    wire               baud_tick;

    assign baud_tick = (baud_cnt == BAUD_DIV - 1);

    // Baud rate counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            baud_cnt <= {DIV_WIDTH{1'b0}};
        else if (state == S_IDLE)
            baud_cnt <= {DIV_WIDTH{1'b0}};
        else if (baud_tick)
            baud_cnt <= {DIV_WIDTH{1'b0}};
        else
            baud_cnt <= baud_cnt + 1'b1;
    end

    // State machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            tx_out    <= 1'b1;
            tx_ready  <= 1'b1;
            bit_idx   <= 3'd0;
            shift_reg <= 8'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    tx_out   <= 1'b1;
                    tx_ready <= 1'b1;
                    if (tx_valid && tx_ready) begin
                        shift_reg <= tx_data;
                        tx_ready  <= 1'b0;
                        tx_out    <= 1'b0; // start bit
                        state     <= S_START;
                    end
                end
                S_START: begin
                    if (baud_tick) begin
                        tx_out  <= shift_reg[0];
                        bit_idx <= 3'd0;
                        state   <= S_DATA;
                    end
                end
                S_DATA: begin
                    if (baud_tick) begin
                        if (bit_idx == 3'd7) begin
                            tx_out <= 1'b1; // stop bit
                            state  <= S_STOP;
                        end else begin
                            bit_idx   <= bit_idx + 1'b1;
                            tx_out    <= shift_reg[bit_idx + 1];
                        end
                    end
                end
                S_STOP: begin
                    if (baud_tick) begin
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
