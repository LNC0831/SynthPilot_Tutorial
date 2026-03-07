//////////////////////////////////////////////////////////////////////////////
// I2C Master Controller
// Standard Mode (100 kbps), 7-bit address, single master
//////////////////////////////////////////////////////////////////////////////
module i2c_master #(
    parameter CLK_FREQ = 100_000_000,
    parameter SCL_FREQ = 100_000
)(
    input  wire        clk,
    input  wire        rst_n,
    // Command interface
    input  wire        cmd_valid,
    output reg         cmd_ready,
    input  wire        cmd_rw,       // 0=write, 1=read
    input  wire [6:0]  cmd_addr,
    input  wire [7:0]  cmd_len,      // 1~256, 0 means 256
    // TX data interface
    input  wire [7:0]  tx_data,
    input  wire        tx_valid,
    output reg         tx_ready,
    // RX data interface
    output reg  [7:0]  rx_data,
    output reg         rx_valid,
    input  wire        rx_ready,
    // Status
    output reg         busy,
    output reg         nack_error,
    // I2C physical interface (active-low open-drain)
    output reg         scl_o,
    output reg         scl_oen,      // 0=drive, 1=release
    input  wire        scl_i,
    output reg         sda_o,
    output reg         sda_oen,      // 0=drive, 1=release
    input  wire        sda_i
);

    // Clock divider: CLK_FREQ / SCL_FREQ = total ticks per SCL period
    // 4 phases, each QUARTER ticks
    localparam integer TOTAL   = CLK_FREQ / SCL_FREQ;
    localparam integer QUARTER = TOTAL / 4;

    // FSM states
    localparam S_IDLE     = 4'd0;
    localparam S_START    = 4'd1;
    localparam S_ADDR     = 4'd2;
    localparam S_ADDR_ACK = 4'd3;
    localparam S_TX_DATA  = 4'd4;
    localparam S_TX_ACK   = 4'd5;
    localparam S_RX_DATA  = 4'd6;
    localparam S_RX_ACK   = 4'd7;
    localparam S_STOP     = 4'd8;
    localparam S_RSTART   = 4'd9;

    reg [3:0]  state;
    reg [1:0]  phase;          // 0..3 within each bit
    reg [15:0] clk_cnt;        // clock divider counter
    reg [3:0]  bit_cnt;        // bit counter within byte (0..7)
    reg [8:0]  byte_cnt;       // byte counter (cmd_len: 0=256 -> 256)
    reg [7:0]  shift_reg;      // shift register for data
    reg        rw_reg;         // stored read/write bit
    reg [6:0]  addr_reg;       // stored slave address
    reg        sda_sample;     // sampled SDA value

    // Latched next command for repeated start
    reg        next_cmd_valid;
    reg        next_cmd_rw;
    reg [6:0]  next_cmd_addr;
    reg [7:0]  next_cmd_len;

    // Phase tick
    wire phase_tick = (clk_cnt == QUARTER - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            phase       <= 2'd0;
            clk_cnt     <= 16'd0;
            bit_cnt     <= 4'd0;
            byte_cnt    <= 9'd0;
            shift_reg   <= 8'd0;
            rw_reg      <= 1'b0;
            addr_reg    <= 7'd0;
            sda_sample  <= 1'b1;
            scl_o       <= 1'b0;
            scl_oen     <= 1'b1;  // release
            sda_o       <= 1'b0;
            sda_oen     <= 1'b1;  // release
            cmd_ready   <= 1'b0;
            tx_ready    <= 1'b0;
            rx_data     <= 8'd0;
            rx_valid    <= 1'b0;
            busy        <= 1'b0;
            nack_error  <= 1'b0;
            next_cmd_valid <= 1'b0;
            next_cmd_rw    <= 1'b0;
            next_cmd_addr  <= 7'd0;
            next_cmd_len   <= 8'd0;
        end else begin
            // Default pulse signals
            nack_error <= 1'b0;
            cmd_ready  <= 1'b0;
            tx_ready   <= 1'b0;

            // Clear rx_valid when handshake completes
            if (rx_valid && rx_ready)
                rx_valid <= 1'b0;

            case (state)
                // --------------------------------------------------------
                S_IDLE: begin
                    scl_oen <= 1'b1;
                    sda_oen <= 1'b1;
                    busy    <= 1'b0;
                    if (cmd_valid) begin
                        cmd_ready <= 1'b1;
                        addr_reg  <= cmd_addr;
                        rw_reg    <= cmd_rw;
                        byte_cnt  <= (cmd_len == 8'd0) ? 9'd256 : {1'b0, cmd_len};
                        busy      <= 1'b1;
                        state     <= S_START;
                        phase     <= 2'd0;
                        clk_cnt   <= 16'd0;
                        // SDA goes low while SCL is high => START
                        sda_oen   <= 1'b0; // drive SDA low
                        sda_o     <= 1'b0;
                    end
                end

                // --------------------------------------------------------
                S_START: begin
                    // Hold SDA low, SCL high for QUARTER, then pull SCL low
                    if (phase_tick) begin
                        clk_cnt <= 16'd0;
                        // After one quarter: pull SCL low, move to ADDR
                        scl_oen <= 1'b0; // drive SCL low
                        scl_o   <= 1'b0;
                        state   <= S_ADDR;
                        phase   <= 2'd0;
                        bit_cnt <= 4'd0;
                        shift_reg <= {addr_reg, rw_reg};
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                // --------------------------------------------------------
                S_ADDR: begin
                    if (phase_tick) begin
                        clk_cnt <= 16'd0;
                        case (phase)
                            2'd0: begin
                                // SCL low: setup SDA with MSB
                                sda_oen <= shift_reg[7] ? 1'b1 : 1'b0;
                                sda_o   <= 1'b0;
                                phase   <= 2'd1;
                            end
                            2'd1: begin
                                // Release SCL (go high)
                                scl_oen <= 1'b1;
                                phase   <= 2'd2;
                            end
                            2'd2: begin
                                // SCL high: sample SDA (for arbitration, not used here)
                                sda_sample <= sda_i;
                                phase <= 2'd3;
                            end
                            2'd3: begin
                                // Pull SCL low
                                scl_oen <= 1'b0;
                                scl_o   <= 1'b0;
                                shift_reg <= {shift_reg[6:0], 1'b0};
                                if (bit_cnt == 4'd7) begin
                                    // All 8 bits sent, go to ACK
                                    state   <= S_ADDR_ACK;
                                    phase   <= 2'd0;
                                    bit_cnt <= 4'd0;
                                end else begin
                                    bit_cnt <= bit_cnt + 1;
                                    phase   <= 2'd0;
                                end
                            end
                        endcase
                    end else begin
                        // Clock stretching detection in phase 1
                        if (phase == 2'd1 && scl_oen == 1'b1 && scl_i == 1'b0) begin
                            // SCL being held low by slave, wait
                        end else begin
                            clk_cnt <= clk_cnt + 1;
                        end
                    end
                end

                // --------------------------------------------------------
                S_ADDR_ACK: begin
                    if (phase_tick) begin
                        clk_cnt <= 16'd0;
                        case (phase)
                            2'd0: begin
                                // SCL low: release SDA for slave to ACK
                                sda_oen <= 1'b1;
                                phase   <= 2'd1;
                            end
                            2'd1: begin
                                // Release SCL
                                scl_oen <= 1'b1;
                                phase   <= 2'd2;
                            end
                            2'd2: begin
                                // Sample ACK
                                sda_sample <= sda_i;
                                phase <= 2'd3;
                            end
                            2'd3: begin
                                // Pull SCL low
                                scl_oen <= 1'b0;
                                scl_o   <= 1'b0;
                                if (sda_sample == 1'b1) begin
                                    // NACK received
                                    nack_error <= 1'b1;
                                    state <= S_STOP;
                                    phase <= 2'd0;
                                end else begin
                                    // ACK received
                                    if (rw_reg) begin
                                        state   <= S_RX_DATA;
                                        bit_cnt <= 4'd0;
                                    end else begin
                                        state   <= S_TX_DATA;
                                        bit_cnt <= 4'd0;
                                    end
                                    phase <= 2'd0;
                                end
                            end
                        endcase
                    end else begin
                        if (phase == 2'd1 && scl_oen == 1'b1 && scl_i == 1'b0) begin
                            // clock stretching
                        end else begin
                            clk_cnt <= clk_cnt + 1;
                        end
                    end
                end

                // --------------------------------------------------------
                S_TX_DATA: begin
                    if (phase_tick) begin
                        clk_cnt <= 16'd0;
                        case (phase)
                            2'd0: begin
                                if (bit_cnt == 4'd0) begin
                                    // Need new data byte
                                    if (tx_valid) begin
                                        shift_reg <= tx_data;
                                        tx_ready  <= 1'b1;
                                        sda_oen   <= tx_data[7] ? 1'b1 : 1'b0;
                                        sda_o     <= 1'b0;
                                        phase     <= 2'd1;
                                    end else begin
                                        // Wait for tx_valid, don't advance
                                        clk_cnt <= 16'd0;
                                    end
                                end else begin
                                    sda_oen <= shift_reg[7] ? 1'b1 : 1'b0;
                                    sda_o   <= 1'b0;
                                    phase   <= 2'd1;
                                end
                            end
                            2'd1: begin
                                scl_oen <= 1'b1;
                                phase   <= 2'd2;
                            end
                            2'd2: begin
                                sda_sample <= sda_i;
                                phase <= 2'd3;
                            end
                            2'd3: begin
                                scl_oen <= 1'b0;
                                scl_o   <= 1'b0;
                                shift_reg <= {shift_reg[6:0], 1'b0};
                                if (bit_cnt == 4'd7) begin
                                    state   <= S_TX_ACK;
                                    phase   <= 2'd0;
                                    bit_cnt <= 4'd0;
                                end else begin
                                    bit_cnt <= bit_cnt + 1;
                                    phase   <= 2'd0;
                                end
                            end
                        endcase
                    end else begin
                        if (phase == 2'd1 && scl_oen == 1'b1 && scl_i == 1'b0) begin
                            // clock stretching
                        end else begin
                            clk_cnt <= clk_cnt + 1;
                        end
                    end
                end

                // --------------------------------------------------------
                S_TX_ACK: begin
                    if (phase_tick) begin
                        clk_cnt <= 16'd0;
                        case (phase)
                            2'd0: begin
                                sda_oen <= 1'b1; // release for ACK
                                phase   <= 2'd1;
                            end
                            2'd1: begin
                                scl_oen <= 1'b1;
                                phase   <= 2'd2;
                            end
                            2'd2: begin
                                sda_sample <= sda_i;
                                phase <= 2'd3;
                            end
                            2'd3: begin
                                scl_oen <= 1'b0;
                                scl_o   <= 1'b0;
                                byte_cnt <= byte_cnt - 1;
                                if (sda_sample == 1'b1) begin
                                    // NACK from slave
                                    nack_error <= 1'b1;
                                    state <= S_STOP;
                                    phase <= 2'd0;
                                end else if (byte_cnt == 9'd1) begin
                                    // Last byte done, check for repeated start
                                    if (next_cmd_valid) begin
                                        state <= S_RSTART;
                                        phase <= 2'd0;
                                    end else begin
                                        state <= S_STOP;
                                        phase <= 2'd0;
                                    end
                                end else begin
                                    state   <= S_TX_DATA;
                                    bit_cnt <= 4'd0;
                                    phase   <= 2'd0;
                                end
                            end
                        endcase
                    end else begin
                        if (phase == 2'd1 && scl_oen == 1'b1 && scl_i == 1'b0) begin
                            // clock stretching
                        end else begin
                            clk_cnt <= clk_cnt + 1;
                        end
                    end
                end

                // --------------------------------------------------------
                S_RX_DATA: begin
                    if (phase_tick) begin
                        clk_cnt <= 16'd0;
                        case (phase)
                            2'd0: begin
                                // Release SDA for slave to drive
                                sda_oen <= 1'b1;
                                phase   <= 2'd1;
                            end
                            2'd1: begin
                                scl_oen <= 1'b1;
                                phase   <= 2'd2;
                            end
                            2'd2: begin
                                // Sample SDA
                                shift_reg <= {shift_reg[6:0], sda_i};
                                phase <= 2'd3;
                            end
                            2'd3: begin
                                scl_oen <= 1'b0;
                                scl_o   <= 1'b0;
                                if (bit_cnt == 4'd7) begin
                                    state   <= S_RX_ACK;
                                    phase   <= 2'd0;
                                    bit_cnt <= 4'd0;
                                end else begin
                                    bit_cnt <= bit_cnt + 1;
                                    phase   <= 2'd0;
                                end
                            end
                        endcase
                    end else begin
                        if (phase == 2'd1 && scl_oen == 1'b1 && scl_i == 1'b0) begin
                            // clock stretching
                        end else begin
                            clk_cnt <= clk_cnt + 1;
                        end
                    end
                end

                // --------------------------------------------------------
                S_RX_ACK: begin
                    if (phase_tick) begin
                        clk_cnt <= 16'd0;
                        case (phase)
                            2'd0: begin
                                // Output received byte
                                rx_data  <= shift_reg;
                                rx_valid <= 1'b1;
                                byte_cnt <= byte_cnt - 1;
                                // Drive ACK or NACK
                                if (byte_cnt == 9'd1) begin
                                    // Last byte: send NACK
                                    if (next_cmd_valid) begin
                                        // Repeated start after this byte: still NACK to end read
                                        sda_oen <= 1'b1; // NACK
                                    end else begin
                                        sda_oen <= 1'b1; // NACK
                                    end
                                end else begin
                                    // More bytes: send ACK
                                    sda_oen <= 1'b0;
                                    sda_o   <= 1'b0;
                                end
                                phase <= 2'd1;
                            end
                            2'd1: begin
                                scl_oen <= 1'b1;
                                phase   <= 2'd2;
                            end
                            2'd2: begin
                                phase <= 2'd3;
                            end
                            2'd3: begin
                                scl_oen <= 1'b0;
                                scl_o   <= 1'b0;
                                if (byte_cnt == 9'd0) begin
                                    // All bytes received
                                    if (next_cmd_valid) begin
                                        state <= S_RSTART;
                                        phase <= 2'd0;
                                    end else begin
                                        state <= S_STOP;
                                        phase <= 2'd0;
                                    end
                                end else begin
                                    state   <= S_RX_DATA;
                                    bit_cnt <= 4'd0;
                                    phase   <= 2'd0;
                                end
                            end
                        endcase
                    end else begin
                        if (phase == 2'd1 && scl_oen == 1'b1 && scl_i == 1'b0) begin
                            // clock stretching
                        end else begin
                            clk_cnt <= clk_cnt + 1;
                        end
                    end
                end

                // --------------------------------------------------------
                S_STOP: begin
                    if (phase_tick) begin
                        clk_cnt <= 16'd0;
                        case (phase)
                            2'd0: begin
                                // SCL low, pull SDA low
                                sda_oen <= 1'b0;
                                sda_o   <= 1'b0;
                                phase   <= 2'd1;
                            end
                            2'd1: begin
                                // Release SCL
                                scl_oen <= 1'b1;
                                phase   <= 2'd2;
                            end
                            2'd2: begin
                                // SCL is high, release SDA => STOP condition
                                sda_oen <= 1'b1;
                                phase   <= 2'd3;
                            end
                            2'd3: begin
                                // Done
                                next_cmd_valid <= 1'b0;
                                state <= S_IDLE;
                            end
                        endcase
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

                // --------------------------------------------------------
                S_RSTART: begin
                    // Generate repeated START: SDA high, SCL high, then SDA low
                    if (phase_tick) begin
                        clk_cnt <= 16'd0;
                        case (phase)
                            2'd0: begin
                                // Release SDA (go high) while SCL is low
                                sda_oen <= 1'b1;
                                phase   <= 2'd1;
                            end
                            2'd1: begin
                                // Release SCL (go high)
                                scl_oen <= 1'b1;
                                phase   <= 2'd2;
                            end
                            2'd2: begin
                                // Pull SDA low while SCL is high => repeated START
                                sda_oen <= 1'b0;
                                sda_o   <= 1'b0;
                                phase   <= 2'd3;
                            end
                            2'd3: begin
                                // Pull SCL low, load new command
                                scl_oen  <= 1'b0;
                                scl_o    <= 1'b0;
                                addr_reg <= next_cmd_addr;
                                rw_reg   <= next_cmd_rw;
                                byte_cnt <= (next_cmd_len == 8'd0) ? 9'd256 : {1'b0, next_cmd_len};
                                next_cmd_valid <= 1'b0;
                                state    <= S_ADDR;
                                phase    <= 2'd0;
                                bit_cnt  <= 4'd0;
                                shift_reg <= {next_cmd_addr, next_cmd_rw};
                            end
                        endcase
                    end else begin
                        clk_cnt <= clk_cnt + 1;
                    end
                end

            endcase

            // Latch next command for repeated start (while busy, in data/ack states)
            if (busy && !next_cmd_valid && cmd_valid &&
                (state == S_TX_DATA || state == S_TX_ACK ||
                 state == S_RX_DATA || state == S_RX_ACK)) begin
                next_cmd_valid <= 1'b1;
                next_cmd_rw    <= cmd_rw;
                next_cmd_addr  <= cmd_addr;
                next_cmd_len   <= cmd_len;
                cmd_ready      <= 1'b1;
            end
        end
    end

endmodule
