module top (
    input  wire       clk,
    input  wire       key_in,
    output wire [3:0] led
);

    wire key_debounced;

    key_debounce u_key_debounce (
        .clk     (clk),
        .rst_n   (key_debounced),
        .key_in  (key_in),
        .key_out (key_debounced)
    );

    blink_led u_blink_led (
        .clk   (clk),
        .rst_n (key_debounced),
        .led   (led)
    );

endmodule
