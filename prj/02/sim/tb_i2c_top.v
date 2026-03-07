`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////
// I2C Master/Slave Testbench
// 8 test cases with PASS/FAIL scoring
//////////////////////////////////////////////////////////////////////////////
module tb_i2c_top;

    // Parameters
    localparam CLK_PERIOD = 10;  // 100 MHz
    localparam SCL_PERIOD = 10000; // 100 kHz = 10us
    localparam BYTE_TIME  = SCL_PERIOD * 10; // ~9 clocks + ACK
    localparam TIMEOUT    = BYTE_TIME * 20;  // generous timeout

    // Signals
    reg         clk;
    reg         rst_n;

    // Master command interface
    reg         m_cmd_valid;
    wire        m_cmd_ready;
    reg         m_cmd_rw;
    reg  [6:0]  m_cmd_addr;
    reg  [7:0]  m_cmd_len;
    reg  [7:0]  m_tx_data;
    reg         m_tx_valid;
    wire        m_tx_ready;
    wire [7:0]  m_rx_data;
    wire        m_rx_valid;
    reg         m_rx_ready;
    wire        m_busy;
    wire        m_nack_error;

    // Master I2C signals
    wire        m_scl_o, m_scl_oen, m_sda_o, m_sda_oen;
    wire        m_scl_i, m_sda_i;

    // Slave data interface
    wire [7:0]  s_rx_data;
    wire        s_rx_valid;
    reg         s_rx_ready;
    reg  [7:0]  s_tx_data;
    reg         s_tx_valid;
    wire        s_tx_ready;
    wire        s_start_det, s_stop_det, s_addr_match, s_rw_bit;

    // Slave I2C signals
    wire        s_scl_o, s_scl_oen, s_sda_o, s_sda_oen;
    wire        s_scl_i, s_sda_i;

    // Wired-AND bus model (open-drain)
    wire scl_bus = (m_scl_oen ? 1'b1 : m_scl_o) & (s_scl_oen ? 1'b1 : s_scl_o);
    wire sda_bus = (m_sda_oen ? 1'b1 : m_sda_o) & (s_sda_oen ? 1'b1 : s_sda_o);

    assign m_scl_i = scl_bus;
    assign s_scl_i = scl_bus;
    assign m_sda_i = sda_bus;
    assign s_sda_i = sda_bus;

    // Scoring
    integer pass_count;
    integer total_tests;

    // Storage for multi-byte tests
    reg [7:0] rx_buf [0:15];
    integer   rx_idx;

    // Clock generation
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // Waveform dump
    initial begin
        $dumpfile("tb_i2c_top.vcd");
        $dumpvars(0, tb_i2c_top);
    end

    // Instantiate master
    i2c_master #(
        .CLK_FREQ(100_000_000),
        .SCL_FREQ(100_000)
    ) u_master (
        .clk       (clk),
        .rst_n     (rst_n),
        .cmd_valid (m_cmd_valid),
        .cmd_ready (m_cmd_ready),
        .cmd_rw    (m_cmd_rw),
        .cmd_addr  (m_cmd_addr),
        .cmd_len   (m_cmd_len),
        .tx_data   (m_tx_data),
        .tx_valid  (m_tx_valid),
        .tx_ready  (m_tx_ready),
        .rx_data   (m_rx_data),
        .rx_valid  (m_rx_valid),
        .rx_ready  (m_rx_ready),
        .busy      (m_busy),
        .nack_error(m_nack_error),
        .scl_o     (m_scl_o),
        .scl_oen   (m_scl_oen),
        .scl_i     (m_scl_i),
        .sda_o     (m_sda_o),
        .sda_oen   (m_sda_oen),
        .sda_i     (m_sda_i)
    );

    // Instantiate slave
    i2c_slave #(
        .SLAVE_ADDR(7'h50)
    ) u_slave (
        .clk       (clk),
        .rst_n     (rst_n),
        .rx_data   (s_rx_data),
        .rx_valid  (s_rx_valid),
        .rx_ready  (s_rx_ready),
        .tx_data   (s_tx_data),
        .tx_valid  (s_tx_valid),
        .tx_ready  (s_tx_ready),
        .start_det (s_start_det),
        .stop_det  (s_stop_det),
        .addr_match(s_addr_match),
        .rw_bit    (s_rw_bit),
        .scl_o     (s_scl_o),
        .scl_oen   (s_scl_oen),
        .scl_i     (s_scl_i),
        .sda_o     (s_sda_o),
        .sda_oen   (s_sda_oen),
        .sda_i     (s_sda_i)
    );

    // ====================================================================
    // Helper tasks
    // ====================================================================

    task wait_idle;
        integer wt;
    begin
        wt = 0;
        while (m_busy && wt < TIMEOUT) begin
            @(posedge clk);
            wt = wt + CLK_PERIOD;
        end
        // Extra settling time
        repeat(100) @(posedge clk);
    end
    endtask

    task master_cmd;
        input [6:0] addr;
        input        rw;
        input [7:0]  len;
    begin
        @(posedge clk);
        m_cmd_valid <= 1'b1;
        m_cmd_addr  <= addr;
        m_cmd_rw    <= rw;
        m_cmd_len   <= len;
        @(posedge clk);
        while (!m_cmd_ready) @(posedge clk);
        @(posedge clk);
        m_cmd_valid <= 1'b0;
    end
    endtask

    task master_send_byte;
        input [7:0] data;
    begin
        m_tx_data  <= data;
        m_tx_valid <= 1'b1;
        @(posedge clk);
        while (!m_tx_ready) @(posedge clk);
        @(posedge clk);
        m_tx_valid <= 1'b0;
    end
    endtask

    task slave_provide_byte;
        input [7:0] data;
    begin
        s_tx_data  <= data;
        s_tx_valid <= 1'b1;
        @(posedge clk);
        while (!s_tx_ready) @(posedge clk);
        @(posedge clk);
        s_tx_valid <= 1'b0;
    end
    endtask

    task wait_master_rx;
        integer wt;
    begin
        wt = 0;
        while (!m_rx_valid && wt < TIMEOUT) begin
            @(posedge clk);
            wt = wt + CLK_PERIOD;
        end
    end
    endtask

    task wait_slave_rx;
        integer wt;
    begin
        wt = 0;
        while (!s_rx_valid && wt < TIMEOUT) begin
            @(posedge clk);
            wt = wt + CLK_PERIOD;
        end
    end
    endtask

    task wait_nack_or_idle;
        integer wt;
    begin
        // First wait for busy to assert
        wt = 0;
        while (!m_busy && wt < TIMEOUT) begin
            @(posedge clk);
            wt = wt + CLK_PERIOD;
        end
        // Then wait for nack_error or busy going low
        while (!m_nack_error && m_busy && wt < TIMEOUT) begin
            @(posedge clk);
            wt = wt + CLK_PERIOD;
        end
    end
    endtask

    // ====================================================================
    // Main test sequence
    // ====================================================================
    initial begin
        // Init
        rst_n       = 0;
        m_cmd_valid = 0;
        m_cmd_rw    = 0;
        m_cmd_addr  = 0;
        m_cmd_len   = 0;
        m_tx_data   = 0;
        m_tx_valid  = 0;
        m_rx_ready  = 1;
        s_rx_ready  = 1;
        s_tx_data   = 0;
        s_tx_valid  = 0;
        pass_count  = 0;
        total_tests = 8;

        // Reset
        repeat(20) @(posedge clk);
        rst_n = 1;
        repeat(20) @(posedge clk);

        // ================================================================
        // TC-01: Single byte write
        // ================================================================
        $display("\n--- TC-01: Single byte write ---");
        fork
            begin
                master_cmd(7'h50, 1'b0, 8'd1);
                master_send_byte(8'hA5);
            end
            begin
                wait_slave_rx;
            end
        join
        wait_idle;
        if (s_rx_data == 8'hA5) begin
            $display("[PASS] TC-01: Single byte write");
            pass_count = pass_count + 1;
        end else begin
            $display("[FAIL] TC-01: Single byte write -- expected=A5, actual=%02X", s_rx_data);
        end

        repeat(200) @(posedge clk);

        // ================================================================
        // TC-02: Single byte read
        // ================================================================
        $display("\n--- TC-02: Single byte read ---");
        fork
            begin
                master_cmd(7'h50, 1'b1, 8'd1);
            end
            begin
                slave_provide_byte(8'h3C);
            end
        join
        wait_master_rx;
        begin : tc02_check
            reg [7:0] captured;
            captured = m_rx_data;
            m_rx_ready = 1'b1;
            wait_idle;
            if (captured == 8'h3C) begin
                $display("[PASS] TC-02: Single byte read");
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] TC-02: Single byte read -- expected=3C, actual=%02X", captured);
            end
        end

        repeat(200) @(posedge clk);

        // ================================================================
        // TC-03: Multi-byte write (4 bytes)
        // ================================================================
        $display("\n--- TC-03: Multi-byte write (4 bytes) ---");
        begin : tc03_block
            reg [7:0] exp_data [0:3];
            reg [7:0] rcv_data [0:3];
            integer i, rcv_cnt;
            reg tc03_pass;

            exp_data[0] = 8'h11;
            exp_data[1] = 8'h22;
            exp_data[2] = 8'h33;
            exp_data[3] = 8'h44;
            rcv_cnt = 0;
            tc03_pass = 1;

            fork
                begin
                    master_cmd(7'h50, 1'b0, 8'd4);
                    master_send_byte(8'h11);
                    master_send_byte(8'h22);
                    master_send_byte(8'h33);
                    master_send_byte(8'h44);
                end
                begin
                    for (i = 0; i < 4; i = i + 1) begin
                        wait_slave_rx;
                        rcv_data[i] = s_rx_data;
                        s_rx_ready = 1'b1;
                        @(posedge clk);
                        // Wait for rx_valid to deassert
                        while (s_rx_valid) @(posedge clk);
                    end
                end
            join
            wait_idle;
            for (i = 0; i < 4; i = i + 1) begin
                if (rcv_data[i] !== exp_data[i]) begin
                    tc03_pass = 0;
                    $display("[FAIL] TC-03: byte %0d expected=%02X actual=%02X", i, exp_data[i], rcv_data[i]);
                end
            end
            if (tc03_pass) begin
                $display("[PASS] TC-03: Multi-byte write (4 bytes)");
                pass_count = pass_count + 1;
            end
        end

        repeat(200) @(posedge clk);

        // ================================================================
        // TC-04: Multi-byte read (4 bytes)
        // ================================================================
        $display("\n--- TC-04: Multi-byte read (4 bytes) ---");
        begin : tc04_block
            reg [7:0] exp_data [0:3];
            reg [7:0] rcv_data [0:3];
            integer i;
            reg tc04_pass;

            exp_data[0] = 8'hAA;
            exp_data[1] = 8'hBB;
            exp_data[2] = 8'hCC;
            exp_data[3] = 8'hDD;
            tc04_pass = 1;

            fork
                begin
                    master_cmd(7'h50, 1'b1, 8'd4);
                end
                begin
                    slave_provide_byte(8'hAA);
                    slave_provide_byte(8'hBB);
                    slave_provide_byte(8'hCC);
                    slave_provide_byte(8'hDD);
                end
                begin
                    for (i = 0; i < 4; i = i + 1) begin
                        wait_master_rx;
                        rcv_data[i] = m_rx_data;
                        m_rx_ready = 1'b1;
                        @(posedge clk);
                        while (m_rx_valid) @(posedge clk);
                    end
                end
            join
            wait_idle;
            for (i = 0; i < 4; i = i + 1) begin
                if (rcv_data[i] !== exp_data[i]) begin
                    tc04_pass = 0;
                    $display("[FAIL] TC-04: byte %0d expected=%02X actual=%02X", i, exp_data[i], rcv_data[i]);
                end
            end
            if (tc04_pass) begin
                $display("[PASS] TC-04: Multi-byte read (4 bytes)");
                pass_count = pass_count + 1;
            end
        end

        repeat(200) @(posedge clk);

        // ================================================================
        // TC-05: Compound read/write (Repeated START)
        // Write register address 0x10, then read 1 byte
        // ================================================================
        $display("\n--- TC-05: Compound read/write (Repeated START) ---");
        begin : tc05_block
            reg [7:0] slave_rcv_addr;
            reg [7:0] master_rcv_data;
            reg tc05_pass;
            tc05_pass = 1;

            fork
                begin
                    // Issue write command (1 byte: register address)
                    master_cmd(7'h50, 1'b0, 8'd1);
                    master_send_byte(8'h10);
                    // While master is still busy, queue the read command
                    // for repeated start
                    master_cmd(7'h50, 1'b1, 8'd1);
                end
                begin
                    // Slave: receive the register address
                    wait_slave_rx;
                    slave_rcv_addr = s_rx_data;
                    s_rx_ready = 1'b1;
                    @(posedge clk);
                    while (s_rx_valid) @(posedge clk);
                    // Now slave provides read data
                    slave_provide_byte(8'hEF);
                end
                begin
                    // Master receives read data
                    wait_master_rx;
                    master_rcv_data = m_rx_data;
                    m_rx_ready = 1'b1;
                end
            join
            wait_idle;
            if (slave_rcv_addr !== 8'h10) begin
                tc05_pass = 0;
                $display("[FAIL] TC-05: reg addr expected=10, actual=%02X", slave_rcv_addr);
            end
            if (master_rcv_data !== 8'hEF) begin
                tc05_pass = 0;
                $display("[FAIL] TC-05: read data expected=EF, actual=%02X", master_rcv_data);
            end
            if (tc05_pass) begin
                $display("[PASS] TC-05: Compound read/write (Repeated START)");
                pass_count = pass_count + 1;
            end
        end

        repeat(200) @(posedge clk);

        // ================================================================
        // TC-06: Address mismatch
        // ================================================================
        $display("\n--- TC-06: Address mismatch ---");
        begin : tc06_block
            reg got_nack;
            got_nack = 0;

            fork
                begin
                    master_cmd(7'h51, 1'b0, 8'd1); // Wrong address
                    m_tx_data  <= 8'hFF;
                    m_tx_valid <= 1'b1;
                end
                begin
                    wait_nack_or_idle;
                    if (m_nack_error) got_nack = 1;
                end
            join
            wait_idle;
            m_tx_valid <= 1'b0;
            if (got_nack) begin
                $display("[PASS] TC-06: Address mismatch");
                pass_count = pass_count + 1;
            end else begin
                $display("[FAIL] TC-06: Address mismatch -- nack_error not detected");
            end
        end

        repeat(200) @(posedge clk);

        // ================================================================
        // TC-07: Back-to-back 3 write transactions
        // ================================================================
        $display("\n--- TC-07: Back-to-back 3 writes ---");
        begin : tc07_block
            reg [7:0] rcv [0:2];
            integer i;
            reg tc07_pass;
            tc07_pass = 1;

            // Transaction 1
            fork
                begin
                    master_cmd(7'h50, 1'b0, 8'd1);
                    master_send_byte(8'hF1);
                end
                begin
                    wait_slave_rx;
                    rcv[0] = s_rx_data;
                    s_rx_ready = 1;
                    @(posedge clk);
                end
            join
            wait_idle;
            repeat(100) @(posedge clk);

            // Transaction 2
            fork
                begin
                    master_cmd(7'h50, 1'b0, 8'd1);
                    master_send_byte(8'hF2);
                end
                begin
                    wait_slave_rx;
                    rcv[1] = s_rx_data;
                    s_rx_ready = 1;
                    @(posedge clk);
                end
            join
            wait_idle;
            repeat(100) @(posedge clk);

            // Transaction 3
            fork
                begin
                    master_cmd(7'h50, 1'b0, 8'd1);
                    master_send_byte(8'hF3);
                end
                begin
                    wait_slave_rx;
                    rcv[2] = s_rx_data;
                    s_rx_ready = 1;
                    @(posedge clk);
                end
            join
            wait_idle;

            if (rcv[0] !== 8'hF1) begin tc07_pass = 0; $display("[FAIL] TC-07: txn1 expected=F1 actual=%02X", rcv[0]); end
            if (rcv[1] !== 8'hF2) begin tc07_pass = 0; $display("[FAIL] TC-07: txn2 expected=F2 actual=%02X", rcv[1]); end
            if (rcv[2] !== 8'hF3) begin tc07_pass = 0; $display("[FAIL] TC-07: txn3 expected=F3 actual=%02X", rcv[2]); end
            if (tc07_pass) begin
                $display("[PASS] TC-07: Back-to-back 3 writes");
                pass_count = pass_count + 1;
            end
        end

        repeat(200) @(posedge clk);

        // ================================================================
        // TC-08: Bus idle detection
        // ================================================================
        $display("\n--- TC-08: Bus idle detection ---");
        begin : tc08_block
            reg tc08_pass;
            tc08_pass = 1;

            fork
                begin
                    master_cmd(7'h50, 1'b0, 8'd1);
                    master_send_byte(8'h55);
                end
                begin
                    wait_slave_rx;
                    s_rx_ready = 1;
                end
            join
            wait_idle;
            repeat(200) @(posedge clk);

            if (m_busy !== 1'b0) begin
                tc08_pass = 0;
                $display("[FAIL] TC-08: busy should be 0 after STOP, actual=%b", m_busy);
            end
            if (scl_bus !== 1'b1) begin
                tc08_pass = 0;
                $display("[FAIL] TC-08: SCL should be 1 after STOP, actual=%b", scl_bus);
            end
            if (sda_bus !== 1'b1) begin
                tc08_pass = 0;
                $display("[FAIL] TC-08: SDA should be 1 after STOP, actual=%b", sda_bus);
            end
            if (tc08_pass) begin
                $display("[PASS] TC-08: Bus idle detection");
                pass_count = pass_count + 1;
            end
        end

        // ================================================================
        // Summary
        // ================================================================
        repeat(100) @(posedge clk);
        $display("\n=== %0d/%0d PASSED ===\n", pass_count, total_tests);
        $finish;
    end

    // Global timeout
    initial begin
        #(TIMEOUT * 30);
        $display("\n[TIMEOUT] Simulation exceeded maximum time");
        $display("\n=== %0d/%0d PASSED ===\n", pass_count, total_tests);
        $finish;
    end

endmodule
