module key_debounce (
    input  wire clk,
    input  wire rst_n,
    input  wire key_in,
    output reg  key_out
);

    // 20ms debounce at 50MHz => 1_000_000 cycles
    localparam DEBOUNCE_MAX = 1_000_000 - 1;

    reg [19:0] cnt;
    reg        key_r0;
    reg        key_r1;

    // Two-stage synchronizer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_r0 <= 1'b1;
            key_r1 <= 1'b1;
        end else begin
            key_r0 <= key_in;
            key_r1 <= key_r0;
        end
    end

    // Debounce counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cnt <= 20'd0;
        else if (key_r1 != key_out)
            cnt <= cnt + 1'b1;
        else
            cnt <= 20'd0;
    end

    // Output register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            key_out <= 1'b1;
        else if (cnt == DEBOUNCE_MAX)
            key_out <= key_r1;
    end

endmodule
