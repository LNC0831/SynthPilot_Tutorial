module blink_led (
    input  wire       clk,
    input  wire       rst_n,
    output reg  [3:0] led
);

    // 50MHz clock, 0.5s toggle => 25_000_000 cycles
    localparam CNT_MAX = 25_000_000 - 1;

    reg [24:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cnt <= 25'd0;
        else if (cnt == CNT_MAX)
            cnt <= 25'd0;
        else
            cnt <= cnt + 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            led <= 4'b0001;
        else if (cnt == CNT_MAX)
            led <= {led[2:0], led[3]};
    end

endmodule
