// Counter Module - Fixed version
// All 9 original bugs have been resolved

module buggy_counter (
    input  wire        clk,
    input  wire        rst,       // Active-high reset (async)
    input  wire        en,
    input  wire        load,
    input  wire [7:0]  load_val,
    input  wire        mode,      // 0: up, 1: down
    output reg  [7:0]  count,
    output reg         overflow,
    output reg         underflow,
    output wire        zero_flag
);

    // Fix 1: Added rst to sensitivity list for proper async reset
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            count     <= 8'b0;
            overflow  <= 1'b0;
            underflow <= 1'b0;   // Fix 4: reset underflow on rst as well
        end else if (en) begin
            if (load) begin
                count     <= load_val;
                overflow  <= 1'b0;
                underflow <= 1'b0;
            end else if (mode == 1'b0) begin
                // Fix 2+4: overflow pulses for one cycle, cleared otherwise
                if (count == 8'hFF) begin
                    overflow <= 1'b1;
                end else begin
                    overflow <= 1'b0;
                end
                count <= count + 1;
            end else begin
                // Fix 3+4: underflow pulses for one cycle, cleared otherwise
                if (count == 8'h00) begin
                    underflow <= 1'b1;
                end else begin
                    underflow <= 1'b0;
                end
                count <= count - 1;
            end
        end else begin
            // When not enabled, clear flags
            overflow  <= 1'b0;
            underflow <= 1'b0;
        end
    end

    // Fix 5+6: Pure combinational logic, no latch
    assign zero_flag = (count == 8'b0);

    // Fix 7: Removed the second always block that was multi-driving count

    // Fix 8: Removed unused debug_state signal

    // Fix 9: Width matched — threshold widened to 8 bits
    wire [7:0] threshold = 8'd10;
    wire over_threshold = (count > threshold);

endmodule
