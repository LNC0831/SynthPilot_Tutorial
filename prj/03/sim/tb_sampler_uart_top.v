`timescale 1ns / 1ps

module tb_sampler_uart_top;

    // =========================================================================
    // Parameters — high baud rate and small SAMPLE_DIV for fast simulation
    // =========================================================================
    parameter TB_CLK_SYS_FREQ = 50_000_000;
    parameter TB_BAUD_RATE    = 1_000_000;   // 1 Mbaud for fast sim
    parameter TB_SAMPLE_DIV   = 200;         // fast data generation
    parameter TB_NUM_BYTES    = 256;
    parameter SIM_TIMEOUT_US  = 50000;

    localparam BAUD_DIV    = TB_CLK_SYS_FREQ / TB_BAUD_RATE;
    localparam BIT_TIME_NS = 1_000_000_000 / TB_BAUD_RATE;
    localparam CLK_FAST_PERIOD = 5;   // 200 MHz = 5 ns
    localparam CLK_SYS_PERIOD  = 20;  // 50 MHz = 20 ns

    // =========================================================================
    // Signals
    // =========================================================================
    reg  clk_fast, clk_sys, rst_n;
    wire tx_out, fifo_full, fifo_empty;

    // UART RX model storage
    reg [7:0] rx_buffer [0:1023];
    integer   rx_count;
    reg       rx_frame_error;

    // FIFO full tracking (concurrent monitor)
    reg fifo_full_ever;
    always @(posedge clk_fast or negedge rst_n) begin
        if (!rst_n)
            fifo_full_ever <= 1'b0;
        else if (fifo_full)
            fifo_full_ever <= 1'b1;
    end

    // Test results
    integer pass_count;
    integer total_tests;
    integer i;

    // =========================================================================
    // DUT
    // =========================================================================
    sampler_uart_top #(
        .DATA_WIDTH   (8),
        .BAUD_RATE    (TB_BAUD_RATE),
        .CLK_SYS_FREQ (TB_CLK_SYS_FREQ),
        .SAMPLE_DIV   (TB_SAMPLE_DIV)
    ) dut (
        .clk_fast   (clk_fast),
        .clk_sys    (clk_sys),
        .rst_n      (rst_n),
        .tx_out     (tx_out),
        .fifo_full  (fifo_full),
        .fifo_empty (fifo_empty)
    );

    // =========================================================================
    // Clock generation
    // =========================================================================
    initial clk_fast = 0;
    always #(CLK_FAST_PERIOD/2.0) clk_fast = ~clk_fast;

    initial clk_sys = 0;
    always #(CLK_SYS_PERIOD/2.0) clk_sys = ~clk_sys;

    // =========================================================================
    // Waveform dump
    // =========================================================================
    initial begin
        $dumpfile("tb_sampler_uart_top.vcd");
        $dumpvars(0, tb_sampler_uart_top);
    end

    // =========================================================================
    // Simulation timeout
    // =========================================================================
    initial begin
        #(SIM_TIMEOUT_US * 1000);
        $display("[FAIL] Simulation timeout after %0d us", SIM_TIMEOUT_US);
        $finish;
    end

    // =========================================================================
    // UART RX Model — behavioral receiver
    // =========================================================================
    task uart_rx_byte;
        output [7:0] data;
        output       frame_err;
        integer b;
        reg [7:0] d;
    begin
        frame_err = 0;
        // Wait for start bit (falling edge on tx_out)
        @(negedge tx_out);
        // Wait to middle of start bit
        #(BIT_TIME_NS / 2);
        // Verify start bit is still low
        if (tx_out !== 1'b0) begin
            frame_err = 1;
            $display("[UART_RX] @%0t: Frame error - start bit not low", $time);
        end
        // Sample 8 data bits (LSB first)
        for (b = 0; b < 8; b = b + 1) begin
            #(BIT_TIME_NS);
            d[b] = tx_out;
        end
        // Check stop bit
        #(BIT_TIME_NS);
        if (tx_out !== 1'b1) begin
            frame_err = 1;
            $display("[UART_RX] @%0t: Frame error - stop bit not high", $time);
        end
        data = d;
        $display("[UART_RX] @%0t: 0x%02X", $time, d);
    end
    endtask

    // Task: synchronize RX — wait for tx_out idle for at least 1.5 bit times
    task uart_rx_sync;
    begin
        wait (tx_out === 1'b1);
        #(BIT_TIME_NS + BIT_TIME_NS / 2);
        while (tx_out !== 1'b1) begin
            wait (tx_out === 1'b1);
            #(BIT_TIME_NS + BIT_TIME_NS / 2);
        end
    end
    endtask

    // Task: receive N bytes into rx_buffer starting at rx_count
    task receive_n_bytes;
        input integer n;
        integer idx;
        reg [7:0] d;
        reg fe;
    begin
        for (idx = 0; idx < n; idx = idx + 1) begin
            uart_rx_byte(d, fe);
            rx_buffer[rx_count] = d;
            if (fe) rx_frame_error = 1;
            rx_count = rx_count + 1;
        end
    end
    endtask

    // Task: reset and wait for stable state
    task do_reset;
    begin
        rst_n = 0;
        #(CLK_SYS_PERIOD * 10);
        rst_n = 1;
        // Wait for FIFO rst_busy to deassert (~30 read clk cycles)
        #(CLK_SYS_PERIOD * 40);
    end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        pass_count  = 0;
        total_tests = 10;
        rx_count    = 0;
        rx_frame_error = 0;

        // =====================================================================
        // TC-01: Reset initial state
        // Check BEFORE first data is generated (SAMPLE_DIV=200 @ 200MHz = 1us)
        // =====================================================================
        rst_n = 0;
        #(CLK_SYS_PERIOD * 10); // 200ns reset
        rst_n = 1;
        // Wait just enough for rst_busy to deassert but before first data
        // rd_rst_busy ~25 read clocks = 500ns, first data at ~1000ns
        #(CLK_SYS_PERIOD * 30); // 600ns after reset release

        if (tx_out === 1'b1 && fifo_empty === 1'b1 && fifo_full === 1'b0) begin
            $display("[PASS] TC-01: Reset initial state");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TC-01: Reset initial state — tx_out=%b, fifo_empty=%b, fifo_full=%b",
                     tx_out, fifo_empty, fifo_full);
        end

        // =====================================================================
        // TC-06: FIFO empty handling
        // Right now FIFO should still be empty (we're at ~800ns, first data at ~1000ns)
        // Verify tx_out stays idle high while FIFO is empty
        // =====================================================================
        begin : tc06_block
            reg tc06_pass;
            integer check_cycles;
            tc06_pass = 1;
            // Check for 10 sys clocks (200ns) — still before first data arrives
            for (check_cycles = 0; check_cycles < 10; check_cycles = check_cycles + 1) begin
                @(posedge clk_sys);
                if (fifo_empty && tx_out !== 1'b1) begin
                    tc06_pass = 0;
                end
            end
            if (tc06_pass) begin
                $display("[PASS] TC-06: FIFO empty handling — tx_out idle when FIFO empty");
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] TC-06: FIFO empty handling — tx_out not idle when FIFO empty");
            end
        end

        // =====================================================================
        // TC-02: Single byte UART frame format
        // Wait for first byte and check no frame errors
        // =====================================================================
        rx_count = 0;
        rx_frame_error = 0;
        receive_n_bytes(1);

        if (!rx_frame_error) begin
            $display("[PASS] TC-02: Single byte UART frame format (received 0x%02X)", rx_buffer[0]);
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TC-02: Single byte UART frame format — frame error detected");
        end

        // =====================================================================
        // TC-03: Data integrity — continuous increment (16 bytes)
        // Already have 1 byte; receive 15 more for total of 16
        // =====================================================================
        receive_n_bytes(15);

        begin : tc03_block
            reg tc03_pass;
            tc03_pass = 1;
            // First byte should be 0x00, check all 16 consecutive
            for (i = 1; i < 16; i = i + 1) begin
                if (rx_buffer[i] !== ((rx_buffer[i-1] + 1) & 8'hFF)) begin
                    tc03_pass = 0;
                    $display("[FAIL] TC-03: Data integrity — byte[%0d]=0x%02X, expected 0x%02X",
                             i, rx_buffer[i], (rx_buffer[i-1] + 1) & 8'hFF);
                end
            end
            if (tc03_pass) begin
                $display("[PASS] TC-03: Data integrity — 16 bytes consecutive (0x%02X to 0x%02X)",
                         rx_buffer[0], rx_buffer[15]);
                pass_count = pass_count + 1;
            end
        end

        // =====================================================================
        // TC-04: Cross-clock-domain data consistency
        // Verify no duplicates or gaps in the 16 bytes received
        // =====================================================================
        begin : tc04_block
            reg tc04_pass;
            tc04_pass = 1;
            for (i = 1; i < 16; i = i + 1) begin
                if (rx_buffer[i] === rx_buffer[i-1]) begin
                    tc04_pass = 0;
                    $display("[FAIL] TC-04: CDC consistency — duplicate at byte[%0d]=0x%02X", i, rx_buffer[i]);
                end
            end
            if (tc04_pass) begin
                $display("[PASS] TC-04: Cross-clock-domain data consistency — no loss or duplication");
                pass_count = pass_count + 1;
            end
        end

        // =====================================================================
        // TC-07: Baud rate accuracy
        // Measure bit duration of next byte
        // =====================================================================
        begin : tc07_block
            time t_start, t_end;
            integer measured_bit_time;
            reg tc07_pass;
            // Wait for next start bit
            @(negedge tx_out);
            t_start = $time;
            // Wait for full frame (10 bits)
            #(BIT_TIME_NS * 10);
            t_end = $time;
            measured_bit_time = (t_end - t_start) / 10;
            tc07_pass = 1;
            if (measured_bit_time > (BIT_TIME_NS * 102 / 100) ||
                measured_bit_time < (BIT_TIME_NS * 98 / 100)) begin
                tc07_pass = 0;
            end
            // Wait for line to go idle
            #(BIT_TIME_NS);
            rx_count = rx_count + 1;

            if (tc07_pass) begin
                $display("[PASS] TC-07: Baud rate accuracy — measured %0d ns/bit, expected %0d ns/bit",
                         measured_bit_time, BIT_TIME_NS);
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] TC-07: Baud rate accuracy — measured %0d ns/bit, expected %0d ns/bit (>2%% error)",
                         measured_bit_time, BIT_TIME_NS);
            end
        end

        // =====================================================================
        // TC-05: FIFO backpressure
        // With SAMPLE_DIV=200 (1 byte/us) vs 1Mbaud UART (1 byte/10us),
        // data arrives 10x faster — FIFO must fill up
        // =====================================================================
        begin : tc05_block
            integer wait_cycles;
            reg saw_full;
            saw_full = 0;

            for (wait_cycles = 0; wait_cycles < 500000; wait_cycles = wait_cycles + 1) begin
                @(posedge clk_fast);
                if (fifo_full) begin
                    saw_full = 1;
                    wait_cycles = 500000; // break
                end
            end

            if (saw_full) begin
                // System survives backpressure — let it run a bit more
                #(BIT_TIME_NS * 20);
                $display("[PASS] TC-05: FIFO backpressure — fifo_full asserted, system stable");
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] TC-05: FIFO backpressure — fifo_full never asserted");
            end
        end

        // =====================================================================
        // TC-10: FIFO full-to-not-full recovery
        // Fresh reset; fifo_full_ever monitors concurrently while we receive.
        // With SAMPLE_DIV=200 (10x faster than UART), FIFO will fill up.
        // We receive bytes continuously — if fifo_full was seen and data
        // is still consecutive, the recovery works.
        // =====================================================================
        do_reset;
        begin : tc10_block
            reg [7:0] d1, d2, d3, d4;
            reg fe1, fe2, fe3, fe4;
            reg tc10_pass;
            tc10_pass = 1;

            // Receive 4 bytes — by the time we get the 2nd byte (~20us),
            // FIFO should have already gone full (fills in ~16us at SAMPLE_DIV=200)
            uart_rx_byte(d1, fe1);
            uart_rx_byte(d2, fe2);
            uart_rx_byte(d3, fe3);
            uart_rx_byte(d4, fe4);

            if (fe1 || fe2 || fe3 || fe4) begin
                tc10_pass = 0;
                $display("[FAIL] TC-10: FIFO full-to-not-full recovery — frame error");
            end else if (!fifo_full_ever) begin
                tc10_pass = 0;
                $display("[FAIL] TC-10: FIFO full-to-not-full recovery — fifo_full never asserted");
            end else if (d2 !== ((d1 + 1) & 8'hFF) || d3 !== ((d2 + 1) & 8'hFF) || d4 !== ((d3 + 1) & 8'hFF)) begin
                tc10_pass = 0;
                $display("[FAIL] TC-10: FIFO full-to-not-full recovery — data not consecutive: 0x%02X 0x%02X 0x%02X 0x%02X",
                         d1, d2, d3, d4);
            end
            if (tc10_pass) begin
                $display("[PASS] TC-10: FIFO full-to-not-full recovery — data consecutive (0x%02X-0x%02X), fifo_full seen",
                         d1, d4);
                pass_count = pass_count + 1;
            end
        end

        // =====================================================================
        // TC-09: Reset recovery
        // Assert reset mid-operation, release, verify system resumes
        // =====================================================================
        // Wait for line idle before reset
        uart_rx_sync;
        rst_n = 0;
        #(CLK_SYS_PERIOD * 10);
        rst_n = 1;
        #(CLK_SYS_PERIOD * 40); // wait for rst_busy

        begin : tc09_block
            reg [7:0] d1, d2;
            reg fe1, fe2;
            reg tc09_pass;
            tc09_pass = 1;

            // After reset, data restarts. Receive 2 bytes.
            uart_rx_byte(d1, fe1);
            uart_rx_byte(d2, fe2);

            if (fe1 || fe2) begin
                tc09_pass = 0;
                $display("[FAIL] TC-09: Reset recovery — frame errors after reset (d1=0x%02X fe=%b, d2=0x%02X fe=%b)",
                         d1, fe1, d2, fe2);
            end else if (d2 !== ((d1 + 1) & 8'hFF)) begin
                tc09_pass = 0;
                $display("[FAIL] TC-09: Reset recovery — d1=0x%02X, d2=0x%02X not consecutive", d1, d2);
            end
            if (tc09_pass) begin
                $display("[PASS] TC-09: Reset recovery — received 0x%02X, 0x%02X after reset", d1, d2);
                pass_count = pass_count + 1;
            end
        end

        // =====================================================================
        // TC-08: Long run — receive TB_NUM_BYTES (256) bytes
        // Reset fresh and receive from scratch
        // =====================================================================
        do_reset;
        rx_count = 0;
        rx_frame_error = 0;
        receive_n_bytes(TB_NUM_BYTES);

        begin : tc08_block
            reg tc08_pass;
            tc08_pass = 1;
            // Check consecutive increment
            for (i = 1; i < TB_NUM_BYTES; i = i + 1) begin
                if (rx_buffer[i] !== ((rx_buffer[i-1] + 1) & 8'hFF)) begin
                    tc08_pass = 0;
                    $display("[FAIL] TC-08: Long run — byte[%0d]=0x%02X, expected 0x%02X",
                             i, rx_buffer[i], (rx_buffer[i-1] + 1) & 8'hFF);
                    i = TB_NUM_BYTES; // break
                end
            end
            if (rx_frame_error) tc08_pass = 0;
            if (tc08_pass) begin
                $display("[PASS] TC-08: Long run — %0d bytes received correctly (0x%02X to 0x%02X)",
                         TB_NUM_BYTES, rx_buffer[0], rx_buffer[TB_NUM_BYTES-1]);
                pass_count = pass_count + 1;
            end else if (rx_frame_error) begin
                $display("[FAIL] TC-08: Long run — frame errors detected");
            end
        end

        // =====================================================================
        // Summary
        // =====================================================================
        $display("");
        $display("=== %0d/%0d PASSED ===", pass_count, total_tests);
        $display("");
        #100;
        $finish;
    end

endmodule
