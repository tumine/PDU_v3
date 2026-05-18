`include "global_config.vh"

module DMEM#(
    parameter DEPTH       = 10,
    parameter MEM_DELAY   = 4
)(
    input                   [ 0 : 0]            clk,

    input                   [ 0 : 0]            req,        // 访存请求保持信号：请求方必须保持到 ready 返回
    input                   [ 0 : 0]            we,         // 1 表示写事务，0 表示读事务
    input                   [ 0 : 0]            line_mode,  // 1 表示 128 位 Cache Line 访问，0 表示 32 位调试字访问
    input                   [DEPTH - 1 : 0]     addr,       // 以 32 位 word 为单位的地址；line_mode=1 时自动对齐到 4-word line
    output          reg     [31 : 0]            rdata,      // 32 位调试读返回；line 读时同步返回 line 的最低地址 word
    input                   [31 : 0]            wdata,      // 32 位调试写数据
    output          reg     [127: 0]            line_rdata, // 128 位 Cache Line 读返回，低地址 word 位于低 32 位
    input                   [127: 0]            line_wdata, // 128 位 Cache Line 写数据，低地址 word 位于低 32 位
    output          reg     [ 0 : 0]            ready       // 事务完成脉冲，高电平持续一个 clk 周期
);

    localparam integer LINE_WORDS        = 4;
    localparam integer WORD_OFFSET_WIDTH = 2;

    localparam STATE_IDLE       = 3'd0;
    localparam STATE_DELAY      = 3'd1;
    localparam STATE_LINE_WRITE = 3'd2;
    localparam STATE_READ_WAIT  = 3'd3;
    localparam STATE_READ_CAP   = 3'd4;
    localparam STATE_DONE       = 3'd5;

    // 真实数据存储阵列按 32 位 word 组织，保持 CPU_DMEM_FILE 的原始格式。
    // 整条 Cache Line 访问由下面的 FSM 拆成 4 次单 word 访问，因此 RAM 始终只有一个同步端口。
    // 这种模板比一周期 4 地址访问更适合映射到 FPGA Block RAM。
    (* ram_style = "block" *) reg [31 : 0] mem [0 : (1 << DEPTH) - 1];

    reg [DEPTH - 1 : 0] ram_addr;
    reg [31 : 0] ram_din;
    reg ram_we;
    reg [31 : 0] ram_dout;

    reg [2 : 0] state;
    reg [31 : 0] delay_cnt;

    reg [DEPTH - 1 : 0] addr_buf;
    reg [31 : 0] wdata_buf;
    reg [127 : 0] line_wdata_buf;
    reg [127 : 0] line_read_buf;
    reg we_buf;
    reg line_mode_buf;
    reg [WORD_OFFSET_WIDTH - 1 : 0] word_step;

    wire [DEPTH - 1 : 0] aligned_line_addr = {addr[DEPTH - 1 : WORD_OFFSET_WIDTH], {WORD_OFFSET_WIDTH{1'b0}}};
    wire [DEPTH - 1 : 0] step_addr = addr_buf + {{(DEPTH - WORD_OFFSET_WIDTH){1'b0}}, word_step};
    wire [31 : 0] step_line_word = line_wdata_buf[word_step * 32 +: 32];

    integer init_id;

    initial begin
        for (init_id = 0; init_id < (1 << DEPTH); init_id = init_id + 1) begin
            mem[init_id] = 32'b0;
        end

        $readmemh(`CPU_DMEM_FILE, mem);

        ram_addr       = {DEPTH{1'b0}};
        ram_din        = 32'b0;
        ram_we         = 1'b0;
        ram_dout       = 32'b0;
        state          = STATE_IDLE;
        delay_cnt      = 32'b0;
        addr_buf       = {DEPTH{1'b0}};
        wdata_buf      = 32'b0;
        line_wdata_buf = 128'b0;
        line_read_buf  = 128'b0;
        we_buf         = 1'b0;
        line_mode_buf  = 1'b0;
        word_step      = {WORD_OFFSET_WIDTH{1'b0}};
        rdata          = 32'b0;
        line_rdata     = 128'b0;
        ready          = 1'b0;
    end

    always @(posedge clk) begin
        // 独立的同步 RAM 端口。控制 FSM 只驱动 ram_addr/ram_din/ram_we，
        // 不直接组合读取 mem 数组，从而贴近 Vivado 推荐的单端口 BRAM 推断模板。
        if (ram_we) begin
            mem[ram_addr] <= ram_din;
        end
        ram_dout <= mem[ram_addr];
    end

    always @(posedge clk) begin
        ready  <= 1'b0;
        ram_we <= 1'b0;

        case (state)
            STATE_IDLE: begin
                if (req) begin
                    // 事务入口只采样一次输入。Cache/PDU 会保持 req 到 ready，
                    // 但等待期间 DMEM 不会重复采样，避免同一访问被启动多次。
                    addr_buf       <= line_mode ? aligned_line_addr : addr;
                    wdata_buf      <= wdata;
                    line_wdata_buf <= line_wdata;
                    line_read_buf  <= 128'b0;
                    we_buf         <= we;
                    line_mode_buf  <= line_mode;
                    word_step      <= {WORD_OFFSET_WIDTH{1'b0}};
                    delay_cnt      <= MEM_DELAY;
                    state          <= STATE_DELAY;
                end
            end

            STATE_DELAY: begin
                if (delay_cnt != 0) begin
                    // 延迟计数模拟后端主存响应时间；计数结束后才驱动真实 RAM 端口。
                    delay_cnt <= delay_cnt - 1'b1;
                end
                else if (we_buf) begin
                    if (line_mode_buf) begin
                        // 整行写从最低地址 word 开始，每拍只写一个 BRAM 地址。
                        ram_addr <= step_addr;
                        ram_din  <= step_line_word;
                        ram_we   <= 1'b1;
                        state    <= STATE_LINE_WRITE;
                    end
                    else begin
                        // 32 位调试写是整字粒度，只写目标 word，不影响其他地址。
                        ram_addr   <= addr_buf;
                        ram_din    <= wdata_buf;
                        ram_we     <= 1'b1;
                        rdata      <= wdata_buf;
                        line_rdata <= {96'b0, wdata_buf};
                        ready      <= 1'b1;
                        state      <= STATE_IDLE;
                    end
                end
                else begin
                    // 同步读先给出地址，下一拍在 READ_CAP 采样 ram_dout。
                    ram_addr <= line_mode_buf ? step_addr : addr_buf;
                    state    <= STATE_READ_WAIT;
                end
            end

            STATE_LINE_WRITE: begin
                if (word_step == LINE_WORDS - 1) begin
                    // 最后一个 word 的写使能已经在上一拍发出；本拍返回 ready。
                    line_rdata <= line_wdata_buf;
                    rdata      <= line_wdata_buf[31 : 0];
                    ready      <= 1'b1;
                    state      <= STATE_IDLE;
                end
                else begin
                    word_step <= word_step + 1'b1;
                    ram_addr  <= addr_buf + {{(DEPTH - WORD_OFFSET_WIDTH){1'b0}}, word_step + 1'b1};
                    ram_din   <= line_wdata_buf[(word_step + 1'b1) * 32 +: 32];
                    ram_we    <= 1'b1;
                end
            end

            STATE_READ_WAIT: begin
                // 给同步 BRAM 一个周期产生 ram_dout。
                state <= STATE_READ_CAP;
            end

            STATE_READ_CAP: begin
                if (line_mode_buf) begin
                    // 采样当前 word，并根据 word_step 放入 line 的对应切片。
                    line_read_buf[word_step * 32 +: 32] <= ram_dout;
                    if (word_step == LINE_WORDS - 1) begin
                        state <= STATE_DONE;
                    end
                    else begin
                        word_step <= word_step + 1'b1;
                        ram_addr  <= addr_buf + {{(DEPTH - WORD_OFFSET_WIDTH){1'b0}}, word_step + 1'b1};
                        state     <= STATE_READ_WAIT;
                    end
                end
                else begin
                    line_read_buf[31 : 0] <= ram_dout;
                    state <= STATE_DONE;
                end
            end

            STATE_DONE: begin
                ready <= 1'b1;
                state <= STATE_IDLE;

                if (line_mode_buf) begin
                    // 上一拍最后一个 word 写入 line_read_buf 使用非阻塞赋值，
                    // 因此 ready 周期用 ram_dout 显式补入最高 word，确保整行返回完整。
                    line_rdata <= {
                        ram_dout,
                        line_read_buf[95 : 0]
                    };
                    rdata <= line_read_buf[31 : 0];
                end
                else begin
                    rdata      <= line_read_buf[31 : 0];
                    line_rdata <= {96'b0, line_read_buf[31 : 0]};
                end
            end

            default: begin
                state <= STATE_IDLE;
            end
        endcase
    end

endmodule
