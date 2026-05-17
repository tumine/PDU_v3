`include "global_config.vh"

module TOP(
    input                   [ 0 : 0]            sys_clk,
    input                   [ 0 : 0]            sys_rst,

    input                   [ 0 : 0]            uart_rxd,
    output                  [ 0 : 0]            uart_txd
);

    wire [31 : 0] pdu_iaddr;
    wire [31 : 0] pdu_idata;

    wire [31 : 0] pdu_daddr;
    wire [31 : 0] pdu_dwdata;
    wire [ 0 : 0] pdu_dwe;
    wire [31 : 0] pdu_drdata;

    wire [31 : 0] imem_interface_addr;
    wire [31 : 0] imem_interface_data;
    wire [31 : 0] dmem_interface_addr;
    wire [31 : 0] dmem_interface_rdata;
    wire [31 : 0] dmem_interface_wdata;
    wire [ 0 : 0] dmem_interface_we;

    wire [31 : 0] uart_interface_addr;
    wire [31 : 0] uart_interface_rdata;
    wire [31 : 0] uart_interface_wdata;
    wire [ 0 : 0] uart_interface_we;

    wire [31 : 0] cpu_ctrl_interface_addr;
    wire [31 : 0] cpu_ctrl_interface_rdata;
    wire [31 : 0] cpu_ctrl_interface_wdata;
    wire [ 0 : 0] cpu_ctrl_interface_we;

    wire [31 : 0] cpu_ctrl_imem_addr;
    wire [31 : 0] cpu_ctrl_imem_rdata;
    wire [31 : 0] cpu_ctrl_imem_wdata;
    wire [ 0 : 0] cpu_ctrl_imem_we;
    wire [31 : 0] cpu_ctrl_dmem_addr;
    wire [31 : 0] cpu_ctrl_dmem_rdata;
    wire [31 : 0] cpu_ctrl_dmem_wdata;
    wire [ 0 : 0] cpu_ctrl_dmem_we;
    wire [ 0 : 0] cpu_ctrl_dmem_req;
    wire [ 0 : 0] cpu_ctrl_dmem_ready_cpu;
    wire [ 0 : 0] cpu_ctrl_dmem_ready_sys;

    wire [ 0 : 0] cpu_rst;
    wire [ 0 : 0] cpu_global_en;
    wire [ 0 : 0] cpu_commit_en;
    wire [31 : 0] cpu_commit_pc;
    wire [31 : 0] cpu_commit_instr;
    wire [ 0 : 0] cpu_commit_halt;
    wire [ 0 : 0] cpu_cache_flush;
    wire [ 4 : 0] cpu_reg_ra;
    wire [31 : 0] cpu_reg_rd;

    wire [31 : 0] cpu_imem_addr;
    wire [31 : 0] cpu_imem_rdata;

    wire [ 0 : 0] cpu_dmem_mem_r;
    wire [ 0 : 0] cpu_dmem_mem_w;
    wire [31 : 0] cpu_dmem_mem_addr;
    wire [127: 0] cpu_dmem_mem_wdata;
    wire [127: 0] cpu_dmem_mem_rdata;
    wire [ 0 : 0] cpu_dmem_mem_ready;

    wire [31 : 0] imem_addr;
    wire [31 : 0] imem_rdata;
    wire [31 : 0] imem_wdata;
    wire [ 0 : 0] imem_we;

    wire [ 0 : 0] dmem_req;
    wire [ 0 : 0] dmem_we;
    wire [ 0 : 0] dmem_line_mode;
    wire [31 : 0] dmem_addr;
    wire [31 : 0] dmem_rdata;
    wire [31 : 0] dmem_wdata;
    wire [127: 0] dmem_line_wdata;
    wire [127: 0] dmem_line_rdata;
    wire [ 0 : 0] dmem_ready;

    wire [ 0 : 0] sys_rst_in;
    wire [ 0 : 0] cpu_clk;

    `ifdef PHYSICAL_BOARD
        assign sys_rst_in = ~sys_rst;
    `endif
    `ifndef PHYSICAL_BOARD
        assign sys_rst_in = sys_rst;
    `endif

    // CPU 使用分频后的时钟。PDU kernel/UART/总线仍运行在 sys_clk。
    clock_divider cpu_clock_divider (
        .sys_clk                        (sys_clk                    ),
        .sys_rst                        (sys_rst_in                 ),
        .cpu_clk                        (cpu_clk                    )
    );

    // sys_clk -> cpu_clk：同步 PDU 给 CPU 的复位和全局运行使能。
    // CPU 内部所有流水线寄存器只看 cpu_clk 域内的同步信号。
    reg cpu_rst_sync;
    reg cpu_global_en_sync;
    reg cpu_rst_sync1, cpu_rst_sync2;
    reg cpu_global_en_sync1, cpu_global_en_sync2;

    initial begin
        cpu_rst_sync = 1'b0;
        cpu_global_en_sync = 1'b0;
        cpu_rst_sync1 = 1'b0;
        cpu_rst_sync2 = 1'b0;
        cpu_global_en_sync1 = 1'b0;
        cpu_global_en_sync2 = 1'b0;
    end

    always @(posedge cpu_clk) begin
        cpu_rst_sync1 <= cpu_rst;
        cpu_rst_sync2 <= cpu_rst_sync1;
        cpu_rst_sync  <= cpu_rst_sync2;

        cpu_global_en_sync1 <= cpu_global_en;
        cpu_global_en_sync2 <= cpu_global_en_sync1;
        cpu_global_en_sync  <= cpu_global_en_sync2;
    end

    wire cpu_ctrl_active = ~cpu_global_en_sync;

    // CPU_ctrl 指令存储器写使能仍沿用原路径：CPU 停止时允许 PDU 写 IMEM。
    // 该信号只影响调试装载指令，与数据 Cache 的延迟握手互不干扰。
    reg cpu_ctrl_imem_we_ext;
    initial begin
        cpu_ctrl_imem_we_ext = 1'b0;
    end

    always @(posedge cpu_clk) begin
        if (cpu_rst_sync) begin
            cpu_ctrl_imem_we_ext <= 1'b0;
        end
        else if (cpu_ctrl_active) begin
            cpu_ctrl_imem_we_ext <= cpu_ctrl_imem_we;
        end
        else begin
            cpu_ctrl_imem_we_ext <= 1'b0;
        end
    end

    // CPU_ctrl 数据存储器请求跨到 cpu_clk 域。
    // 这里不把 req 直接接到 DMEM：CPU_ctrl 会一直保持 req 直到 ready，
    // 若直接连接，ready 同步回 sys_clk 前可能在 cpu_clk 域重复启动第二次事务。
    // 因此在 cpu_clk 域检测 req 上升沿，只生成一个 pending 事务，DMEM ready 后清除。
    reg cpu_ctrl_dmem_req_meta;
    reg cpu_ctrl_dmem_req_sync;
    reg cpu_ctrl_dmem_req_prev;
    reg cpu_ctrl_dmem_req_pending;
    reg cpu_cache_flush_cpu;
    reg cpu_ctrl_dmem_we_cpu;
    reg [31 : 0] cpu_ctrl_dmem_addr_cpu;
    reg [31 : 0] cpu_ctrl_dmem_wdata_cpu;

    wire cpu_ctrl_dmem_req_rise = cpu_ctrl_dmem_req_sync & ~cpu_ctrl_dmem_req_prev;

    initial begin
        cpu_ctrl_dmem_req_meta = 1'b0;
        cpu_ctrl_dmem_req_sync = 1'b0;
        cpu_ctrl_dmem_req_prev = 1'b0;
        cpu_ctrl_dmem_req_pending = 1'b0;
        cpu_cache_flush_cpu = 1'b0;
        cpu_ctrl_dmem_we_cpu = 1'b0;
        cpu_ctrl_dmem_addr_cpu = 32'b0;
        cpu_ctrl_dmem_wdata_cpu = 32'b0;
    end

    always @(posedge cpu_clk) begin
        if (cpu_rst_sync) begin
            cpu_ctrl_dmem_req_meta <= 1'b0;
            cpu_ctrl_dmem_req_sync <= 1'b0;
            cpu_ctrl_dmem_req_prev <= 1'b0;
            cpu_ctrl_dmem_req_pending <= 1'b0;
            cpu_cache_flush_cpu <= 1'b0;
            cpu_ctrl_dmem_we_cpu <= 1'b0;
            cpu_ctrl_dmem_addr_cpu <= 32'b0;
            cpu_ctrl_dmem_wdata_cpu <= 32'b0;
        end
        else begin
            cpu_cache_flush_cpu <= 1'b0;
            cpu_ctrl_dmem_req_meta <= cpu_ctrl_dmem_req;
            cpu_ctrl_dmem_req_sync <= cpu_ctrl_dmem_req_meta;
            cpu_ctrl_dmem_req_prev <= cpu_ctrl_dmem_req_sync;

            if (cpu_ctrl_dmem_req_rise && cpu_ctrl_active) begin
                // 锁存 CPU_ctrl 在 sys_clk 域已经保持稳定的调试地址/写数据。
                cpu_ctrl_dmem_req_pending <= 1'b1;
                cpu_ctrl_dmem_we_cpu <= cpu_ctrl_dmem_we;
                cpu_ctrl_dmem_addr_cpu <= cpu_ctrl_dmem_addr;
                cpu_ctrl_dmem_wdata_cpu <= cpu_ctrl_dmem_wdata;
            end
            else if (cpu_ctrl_dmem_ready_cpu) begin
                cpu_ctrl_dmem_req_pending <= 1'b0;
                // PDU 调试写直接修改后端 DMEM。写完成后给 CPU 一个 cpu_clk 周期的 Cache flush，
                // 确保 CPU 后续运行不会命中写入前的旧 Cache Line。
                if (cpu_ctrl_dmem_we_cpu) begin
                    cpu_cache_flush_cpu <= 1'b1;
                end
            end
        end
    end

    assign cpu_cache_flush = cpu_cache_flush_cpu;

    // cpu_clk -> sys_clk：DMEM ready 和返回数据同步给 CPU_ctrl。
    // ready 是 cpu_clk 域的宽脉冲，sys_clk 更快，两级同步后 CPU_ctrl 再 ACK 给 PDU。
    reg [31:0] cpu_ctrl_imem_rdata_sync1, cpu_ctrl_imem_rdata_sync2;
    reg [31:0] cpu_ctrl_dmem_rdata_sync1, cpu_ctrl_dmem_rdata_sync2;
    reg cpu_ctrl_dmem_ready_sync1, cpu_ctrl_dmem_ready_sync2;

    initial begin
        cpu_ctrl_imem_rdata_sync1 = 32'b0;
        cpu_ctrl_imem_rdata_sync2 = 32'b0;
        cpu_ctrl_dmem_rdata_sync1 = 32'b0;
        cpu_ctrl_dmem_rdata_sync2 = 32'b0;
        cpu_ctrl_dmem_ready_sync1 = 1'b0;
        cpu_ctrl_dmem_ready_sync2 = 1'b0;
    end

    always @(posedge sys_clk) begin
        if (sys_rst_in) begin
            cpu_ctrl_imem_rdata_sync1 <= 32'b0;
            cpu_ctrl_imem_rdata_sync2 <= 32'b0;
            cpu_ctrl_dmem_rdata_sync1 <= 32'b0;
            cpu_ctrl_dmem_rdata_sync2 <= 32'b0;
            cpu_ctrl_dmem_ready_sync1 <= 1'b0;
            cpu_ctrl_dmem_ready_sync2 <= 1'b0;
        end
        else begin
            cpu_ctrl_imem_rdata_sync1 <= imem_rdata;
            cpu_ctrl_imem_rdata_sync2 <= cpu_ctrl_imem_rdata_sync1;
            cpu_ctrl_dmem_rdata_sync1 <= cpu_ctrl_dmem_rdata;
            cpu_ctrl_dmem_rdata_sync2 <= cpu_ctrl_dmem_rdata_sync1;
            cpu_ctrl_dmem_ready_sync1 <= cpu_ctrl_dmem_ready_cpu;
            cpu_ctrl_dmem_ready_sync2 <= cpu_ctrl_dmem_ready_sync1;
        end
    end

    assign cpu_ctrl_dmem_ready_sys = cpu_ctrl_dmem_ready_sync2;

    PDU_kernel pdu_kernel(
        .sys_clk                        (sys_clk                    ),
        .sys_rst                        (sys_rst_in                 ),
        .imem_addr                      (pdu_iaddr                  ),
        .imem_rdata                     (pdu_idata                  ),
        .dmem_addr                      (pdu_daddr                  ),
        .dmem_wdata                     (pdu_dwdata                 ),
        .dmem_we                        (pdu_dwe                    ),
        .dmem_rdata                     (pdu_drdata                 )
    );

    PDU_BUS pdu_bus(
        .pdu_iaddr                      (pdu_iaddr                  ),
        .pdu_idata                      (pdu_idata                  ),
        .pdu_daddr                      (pdu_daddr                  ),
        .pdu_dwdata                     (pdu_dwdata                 ),
        .pdu_dwe                        (pdu_dwe                    ),
        .pdu_drdata                     (pdu_drdata                 ),
        .imem_interface_addr            (imem_interface_addr        ),
        .imem_interface_data            (imem_interface_data        ),
        .dmem_interface_addr            (dmem_interface_addr        ),
        .dmem_interface_rdata           (dmem_interface_rdata       ),
        .dmem_interface_wdata           (dmem_interface_wdata       ),
        .dmem_interface_we              (dmem_interface_we          ),
        .uart_interface_addr            (uart_interface_addr        ),
        .uart_interface_rdata           (uart_interface_rdata       ),
        .uart_interface_wdata           (uart_interface_wdata       ),
        .uart_interface_we              (uart_interface_we          ),
        .cpu_ctrl_interface_addr        (cpu_ctrl_interface_addr    ),
        .cpu_ctrl_interface_rdata       (cpu_ctrl_interface_rdata   ),
        .cpu_ctrl_interface_wdata       (cpu_ctrl_interface_wdata   ),
        .cpu_ctrl_interface_we          (cpu_ctrl_interface_we      )
    );

    localparam PDU_IMEM_DEPTH = 12;
    localparam PDU_DMEM_DEPTH = 12;

    PDU_IMEM#(
        .DEPTH                          (PDU_IMEM_DEPTH                                 )
    ) pdu_imem (
        .sys_clk                        (sys_clk                                        ),
        .interface_addr                 (imem_interface_addr[PDU_IMEM_DEPTH + 1 : 2]    ),
        .interface_data                 (imem_interface_data                            )
    );

    PDU_DMEM#(
        .DEPTH                          (PDU_DMEM_DEPTH                                 )
    ) pdu_dmem (
        .sys_clk                        (sys_clk                                        ),
        .interface_addr                 (dmem_interface_addr[PDU_DMEM_DEPTH + 1 : 2]    ),
        .interface_rdata                (dmem_interface_rdata                           ),
        .interface_wdata                (dmem_interface_wdata                           ),
        .interface_we                   (dmem_interface_we                              )
    );

    PDU_UART pdu_uart(
        .sys_clk                        (sys_clk                    ),
        .sys_rst                        (sys_rst_in                 ),
        .interface_addr                 (uart_interface_addr        ),
        .interface_rdata                (uart_interface_rdata       ),
        .interface_wdata                (uart_interface_wdata       ),
        .interface_we                   (uart_interface_we          ),
        .uart_rxd                       (uart_rxd                   ),
        .uart_txd                       (uart_txd                   )
    );

    CPU_ctrl cpu_ctrl(
        .sys_clk                        (sys_clk                    ),
        .sys_rst                        (sys_rst_in                 ),
        .interface_addr                 (cpu_ctrl_interface_addr    ),
        .interface_rdata                (cpu_ctrl_interface_rdata   ),
        .interface_wdata                (cpu_ctrl_interface_wdata   ),
        .interface_we                   (cpu_ctrl_interface_we      ),
        .imem_addr                      (cpu_ctrl_imem_addr         ),
        .imem_rdata                     (cpu_ctrl_imem_rdata_sync2  ),
        .imem_wdata                     (cpu_ctrl_imem_wdata        ),
        .imem_we                        (cpu_ctrl_imem_we           ),
        .dmem_addr                      (cpu_ctrl_dmem_addr         ),
        .dmem_rdata                     (cpu_ctrl_dmem_rdata_sync2  ),
        .dmem_wdata                     (cpu_ctrl_dmem_wdata        ),
        .dmem_we                        (cpu_ctrl_dmem_we           ),
        .dmem_req                       (cpu_ctrl_dmem_req          ),
        .dmem_ready                     (cpu_ctrl_dmem_ready_sys    ),
        .cpu_rst                        (cpu_rst                    ),
        .cpu_global_en                  (cpu_global_en              ),
        .cpu_commit_en                  (cpu_commit_en              ),
        .cpu_commit_pc                  (cpu_commit_pc              ),
        .cpu_commit_instr               (cpu_commit_instr           ),
        .cpu_commit_halt                (cpu_commit_halt            ),
        .cpu_reg_ra                     (cpu_reg_ra                 ),
        .cpu_reg_rd                     (cpu_reg_rd                 )
    );

    CPU cpu(
        .clk                            (cpu_clk                    ),
        .rst                            (cpu_rst_sync               ),
        .global_en                      (cpu_global_en_sync         ),
        .cache_flush                    (cpu_cache_flush            ),
        .imem_raddr                     (cpu_imem_addr              ),
        .imem_rdata                     (cpu_imem_rdata             ),
        .dmem_mem_r                     (cpu_dmem_mem_r             ),
        .dmem_mem_w                     (cpu_dmem_mem_w             ),
        .dmem_mem_addr                  (cpu_dmem_mem_addr          ),
        .dmem_mem_wdata                 (cpu_dmem_mem_wdata         ),
        .dmem_mem_rdata                 (cpu_dmem_mem_rdata         ),
        .dmem_mem_ready                 (cpu_dmem_mem_ready         ),
        .commit                         (cpu_commit_en              ),
        .commit_pc                      (cpu_commit_pc              ),
        .commit_instr                   (cpu_commit_instr           ),
        .commit_halt                    (cpu_commit_halt            ),
        .commit_reg_we                  (                           ),
        .commit_reg_wa                  (                           ),
        .commit_reg_wd                  (                           ),
        .commit_dmem_we                 (                           ),
        .commit_dmem_wa                 (                           ),
        .commit_dmem_wd                 (                           ),
        .debug_reg_ra                   (cpu_reg_ra                 ),
        .debug_reg_rd                   (cpu_reg_rd                 )
    );

    MEM_ARBITER mem_arbiter(
        .cpu_global_en                  (cpu_global_en_sync         ),
        .cpu_imem_addr                  (cpu_imem_addr              ),
        .cpu_imem_rdata                 (cpu_imem_rdata             ),
        .cpu_dmem_mem_r                 (cpu_dmem_mem_r             ),
        .cpu_dmem_mem_w                 (cpu_dmem_mem_w             ),
        .cpu_dmem_mem_addr              (cpu_dmem_mem_addr          ),
        .cpu_dmem_mem_wdata             (cpu_dmem_mem_wdata         ),
        .cpu_dmem_mem_rdata             (cpu_dmem_mem_rdata         ),
        .cpu_dmem_mem_ready             (cpu_dmem_mem_ready         ),
        .cpu_ctrl_imem_addr             (cpu_ctrl_imem_addr         ),
        .cpu_ctrl_imem_rdata            (cpu_ctrl_imem_rdata        ),
        .cpu_ctrl_imem_wdata            (cpu_ctrl_imem_wdata        ),
        .cpu_ctrl_imem_we               (cpu_ctrl_imem_we_ext       ),
        .cpu_ctrl_dmem_addr             (cpu_ctrl_dmem_addr_cpu     ),
        .cpu_ctrl_dmem_rdata            (cpu_ctrl_dmem_rdata        ),
        .cpu_ctrl_dmem_wdata            (cpu_ctrl_dmem_wdata_cpu    ),
        .cpu_ctrl_dmem_we               (cpu_ctrl_dmem_we_cpu       ),
        .cpu_ctrl_dmem_req              (cpu_ctrl_dmem_req_pending  ),
        .cpu_ctrl_dmem_ready            (cpu_ctrl_dmem_ready_cpu    ),
        .imem_addr                      (imem_addr                  ),
        .imem_rdata                     (imem_rdata                 ),
        .imem_wdata                     (imem_wdata                 ),
        .imem_we                        (imem_we                    ),
        .dmem_req                       (dmem_req                   ),
        .dmem_we                        (dmem_we                    ),
        .dmem_line_mode                 (dmem_line_mode             ),
        .dmem_addr                      (dmem_addr                  ),
        .dmem_rdata                     (dmem_rdata                 ),
        .dmem_wdata                     (dmem_wdata                 ),
        .dmem_line_wdata                (dmem_line_wdata            ),
        .dmem_line_rdata                (dmem_line_rdata            ),
        .dmem_ready                     (dmem_ready                 )
    );

    localparam IMEM_DEPTH = 10;
    localparam DMEM_DEPTH = 10;

    wire [31 : 0] imem_addr_offset = imem_addr - `IMEM_START_ADDR;
    wire [31 : 0] dmem_addr_offset = dmem_addr - `DMEM_START_ADDR;

    IMEM #(
        .DEPTH                          (IMEM_DEPTH                             )
    ) imem (
        .clk                            (cpu_clk                                ),
        .addr                           (imem_addr_offset[IMEM_DEPTH + 1 : 2]   ),
        .rdata                          (imem_rdata                             ),
        .wdata                          (imem_wdata                             ),
        .we                             (imem_we                                )
    );

    DMEM #(
        .DEPTH                          (DMEM_DEPTH                             ),
        .MEM_DELAY                      (4                                      )
    ) dmem (
        .clk                            (cpu_clk                                ),
        .req                            (dmem_req                               ),
        .we                             (dmem_we                                ),
        .line_mode                      (dmem_line_mode                         ),
        .addr                           (dmem_addr_offset[DMEM_DEPTH + 1 : 2]   ),
        .rdata                          (dmem_rdata                             ),
        .wdata                          (dmem_wdata                             ),
        .line_rdata                     (dmem_line_rdata                        ),
        .line_wdata                     (dmem_line_wdata                        ),
        .ready                          (dmem_ready                             )
    );

endmodule
