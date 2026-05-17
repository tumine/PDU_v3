`ifndef INSTR_MEM_START
  `define INSTR_MEM_START 32'H00400000
`endif
`ifndef INSTR_MEM_DEPTH
  `define INSTR_MEM_DEPTH 16
`endif
`ifndef DATA_MEM_START
  `define DATA_MEM_START 32'H10010000
`endif
`ifndef DATA_MEM_DEPTH
  `define DATA_MEM_DEPTH 16
`endif

module CPU (
    input                   [ 0 : 0]            clk,
    input                   [ 0 : 0]            rst,
    input                   [ 0 : 0]            global_en,

/* ------------------------------ Memory (inst) ----------------------------- */
    output                  [31 : 0]            imem_raddr,
    input                   [31 : 0]            imem_rdata,

/* ------------------------------ Memory (data) ----------------------------- */
    input                   [31 : 0]            dmem_rdata,
    output                  [ 0 : 0]            dmem_we,
    output                  [31 : 0]            dmem_addr,
    output                  [31 : 0]            dmem_wdata,

/* ---------------------------------- Debug --------------------------------- */
    output                  [ 0 : 0]            commit,
    output                  [31 : 0]            commit_pc,
    output                  [31 : 0]            commit_instr,
    output                  [ 0 : 0]            commit_halt,
    output                  [ 0 : 0]            commit_reg_we,
    output                  [ 4 : 0]            commit_reg_wa,
    output                  [31 : 0]            commit_reg_wd,
    output                  [ 0 : 0]            commit_dmem_we,
    output                  [31 : 0]            commit_dmem_wa,
    output                  [31 : 0]            commit_dmem_wd,

    input                   [ 4 : 0]            debug_reg_ra,
    output                  [31 : 0]            debug_reg_rd
);
    // 5 级流水线：IF-ID-EX-MEM-WB

    // ========================= IF Stage =========================
    // 本阶段主要根据 PC 取指，计算下一条连续指令的地址 PC + 4
    // 产生的主要信号和数据：当前 PC pc_IF，指令内存访存地址 imem_raddr，读取出的指令 inst_IF，PC+4 pc_plus_4_IF
    wire [31:0] next_pc;
    wire [31:0] pc_IF;

    reg [31:0] pc_reg;
    always @(posedge clk) begin
        if (rst) begin
            pc_reg <= `INSTR_MEM_START;
        end
        else if (global_en && !pc_stall) begin
            pc_reg <= next_pc;
        end
    end
    assign pc_IF = pc_reg;
    assign imem_raddr = pc_IF;

    wire        mem_out_bounds = (pc_IF < `INSTR_MEM_START)
                              || (pc_IF >= `INSTR_MEM_START + (1 << (`INSTR_MEM_DEPTH + 2)));
    wire [31:0] inst_IF = mem_out_bounds ? 32'h13 : imem_rdata; // PC 越界，执行 NOP
    wire [31:0] pc_plus_4_IF = pc_IF + 4;
    wire        commit_IF = 1'b1;

    // ========================= IF/ID Pipeline Register =========================
    wire [31:0] pc_ID, inst_ID, pc_plus_4_ID;
    wire        commit_ID;

    seg_reg if_id_reg (
        .clk(clk), .rst(rst), .en(global_en), .stall(if_id_stall), .flush(if_id_flush),
        .pc_in(pc_IF), .inst_in(inst_IF), .pc_plus_4_in(pc_plus_4_IF), .commit_in(commit_IF),
        .pc_out(pc_ID), .inst_out(inst_ID), .pc_plus_4_out(pc_plus_4_ID), .commit_out(commit_ID),
        // unused signals
        .rs1_in(5'b0), .rs2_in(5'b0), .rd_in(5'b0), .imm_in(32'b0), .rf_rdata1_in(32'b0), .rf_rdata2_in(32'b0),
        .pc_sel_in(1'b0), .rf_we_in(1'b0), .wb_sel_in(2'b0), .alu_src_a_in(1'b0), .alu_src_b_in(1'b0),
        .alu_op_in(5'b0), .cmp_op_in(3'b0), .mem_write_in(1'b0), .mem_read_in(1'b0), .is_jalr_in(1'b0), .halt_in(1'b0),
        .opcode_in(7'b0), .funct3_in(3'b0), .funct7_in(7'b0), .cmp_res_in(1'b0), .alu_out_in(32'b0), .mem_read_data_in(32'b0),
        .rs1_out(), .rs2_out(), .rd_out(), .imm_out(), .rf_rdata1_out(), .rf_rdata2_out(),
        .pc_sel_out(), .rf_we_out(), .wb_sel_out(), .alu_src_a_out(), .alu_src_b_out(),
        .alu_op_out(), .cmp_op_out(), .mem_write_out(), .mem_read_out(), .is_jalr_out(), .halt_out(),
        .opcode_out(), .funct3_out(), .funct7_out(), .cmp_res_out(), .alu_out_out(), .mem_read_data_out()
    );

    // ========================= ID Stage =========================
    // 本阶段主要对指令进行译码，读取寄存器堆，生成立即数
    // 产生的主要信号和数据：寄存器索引 rs1/rs2/rd_ID，立即数 imm_ID，寄存器读出的数据 rf_rdata1/2_ID，译码器输出的控制信号
    wire [4:0]  rs1_ID     = inst_ID[19:15];
    wire [4:0]  rs2_ID     = inst_ID[24:20];
    wire [4:0]  rd_ID      = inst_ID[11:7];
    wire [2:0]  funct3_ID  = inst_ID[14:12];
    wire [6:0]  funct7_ID  = inst_ID[31:25];
    wire [6:0]  opcode_ID  = inst_ID[6:0];
    wire [31:0] imm_ID;

    wire [31:0] rf_rdata1_ID, rf_rdata2_ID;

    wire [31:0] forwarded_rf_rdata1_ID, forwarded_rf_rdata2_ID;

    // 来自 WB 阶段的写回信号
    wire        rf_we_WB;
    wire [4:0]  rd_WB;
    wire [31:0] rf_wdata_WB;

    regfile u_regfile (
        .clk        (clk),
        .we         (rf_we_WB && global_en),
        .rs1        (rs1_ID),
        .rs2        (rs2_ID),
        .rd         (rd_WB),
        .wdata      (rf_wdata_WB),
        .rdata1     (rf_rdata1_ID),
        .rdata2     (rf_rdata2_ID),
        .debug_ra   (debug_reg_ra),
        .debug_rd   (debug_reg_rd)
    );

    imm_gen u_imm_gen (
        .inst       (inst_ID),
        .imm        (imm_ID)
    );

    // 译码器输出控制信号
    wire        rf_we_ID;
    wire [1:0]  wb_sel_ID;
    wire        alu_src_a_ID;
    wire        alu_src_b_ID;
    wire [4:0]  alu_op_ID;
    wire [2:0]  cmp_op_ID;
    wire        mem_write_ID;
    wire        mem_read_ID;
    wire        is_jalr_ID;
    wire        halt_ID;

    // 分支判断结果 cmp_res 尚未产生，传递给译码器的 cmp_res 为 0
    decoder u_decoder (
        .opcode     (opcode_ID),
        .funct3     (funct3_ID),
        .funct7     (funct7_ID),
        .cmp_res    (1'b0),     // 分支判断结果尚未产生
        .inst20     (inst_ID[20]),

        .rf_we      (rf_we_ID),
        .wb_sel     (wb_sel_ID),
        .alu_src_a  (alu_src_a_ID),
        .alu_src_b  (alu_src_b_ID),
        .alu_op     (alu_op_ID),
        .cmp_op     (cmp_op_ID),
        .mem_write  (mem_write_ID),
        .mem_read   (mem_read_ID),
        .is_jalr    (is_jalr_ID),
        .halt       (halt_ID)
    );

    // ========================= ID/EX Pipeline Register =========================
    wire [31:0] pc_EX, inst_EX, pc_plus_4_EX;
    wire        commit_EX;
    wire [4:0]  rs1_EX, rs2_EX, rd_EX;
    wire [31:0] imm_EX, rf_rdata1_EX, rf_rdata2_EX;
    wire        rf_we_EX, alu_src_a_EX, alu_src_b_EX, mem_write_EX, mem_read_EX, is_jalr_EX, halt_EX;
    wire [1:0]  wb_sel_EX;
    wire [4:0]  alu_op_EX;
    wire [2:0]  cmp_op_EX;
    wire [6:0]  opcode_EX;
    wire [2:0]  funct3_EX;
    wire [6:0]  funct7_EX;

    seg_reg id_ex_reg (
        .clk(clk), .rst(rst), .en(global_en), .stall(stall), .flush(id_ex_flush),
        .pc_in(pc_ID), .inst_in(inst_ID), .pc_plus_4_in(pc_plus_4_ID), .commit_in(commit_ID),
        .rs1_in(rs1_ID), .rs2_in(rs2_ID), .rd_in(rd_ID), .imm_in(imm_ID), .rf_rdata1_in(forwarded_rf_rdata1_ID), .rf_rdata2_in(forwarded_rf_rdata2_ID),
        .rf_we_in(rf_we_ID), .wb_sel_in(wb_sel_ID), .alu_src_a_in(alu_src_a_ID), .alu_src_b_in(alu_src_b_ID),
        .alu_op_in(alu_op_ID), .cmp_op_in(cmp_op_ID), .mem_write_in(mem_write_ID), .mem_read_in(mem_read_ID), .is_jalr_in(is_jalr_ID), .halt_in(halt_ID),
        .opcode_in(opcode_ID), .funct3_in(funct3_ID), .funct7_in(funct7_ID),
        
        .pc_out(pc_EX), .inst_out(inst_EX), .pc_plus_4_out(pc_plus_4_EX), .commit_out(commit_EX),
        .rs1_out(rs1_EX), .rs2_out(rs2_EX), .rd_out(rd_EX), .imm_out(imm_EX), .rf_rdata1_out(rf_rdata1_EX), .rf_rdata2_out(rf_rdata2_EX),
        .rf_we_out(rf_we_EX), .wb_sel_out(wb_sel_EX), .alu_src_a_out(alu_src_a_EX), .alu_src_b_out(alu_src_b_EX),
        .alu_op_out(alu_op_EX), .cmp_op_out(cmp_op_EX), .mem_write_out(mem_write_EX), .mem_read_out(mem_read_EX), .is_jalr_out(is_jalr_EX), .halt_out(halt_EX),
        .opcode_out(opcode_EX), .funct3_out(funct3_EX), .funct7_out(funct7_EX),
        // unused
        .pc_sel_in(1'b0), .cmp_res_in(1'b0), .alu_out_in(32'b0), .mem_read_data_in(32'b0),
        .pc_sel_out(), .cmp_res_out(), .alu_out_out(), .mem_read_data_out()
    );

    // ========================= EX Stage =========================
    // 本阶段主要执行算术逻辑运算和分支比较，判断跳转并计算下一条指令地址
    // 产生的主要信号和数据：ALU 运算结果 alu_out_EX，比较结果 cmp_res_EX，分支条件与跳转选择信号 pc_sel_EX，PC 新值 next_pc
    
    wire [31:0] forwarded_rdata1_EX;
    wire [31:0] forwarded_rdata2_EX;

    wire [31:0] alu_in_a = alu_src_a_EX ? pc_EX : forwarded_rdata1_EX;
    wire [31:0] alu_in_b = alu_src_b_EX ? imm_EX : forwarded_rdata2_EX;
    wire [31:0] alu_out_EX;
    wire        cmp_res_EX;

    alu u_alu (
        .a          (alu_in_a),
        .b          (alu_in_b),
        .op         (alu_op_EX),
        .out        (alu_out_EX)
    );

    cmp u_cmp (
        .a          (forwarded_rdata1_EX),
        .b          (forwarded_rdata2_EX),
        .op         (cmp_op_EX),
        .res        (cmp_res_EX)
    );

    // 重新计算 pc_sel
    wire is_branch_EX = (opcode_EX == 7'b1100011);
    wire is_jal_EX    = (opcode_EX == 7'b1101111);
    wire pc_sel_EX    = is_branch_EX ? cmp_res_EX : (is_jal_EX | is_jalr_EX);

    // PC 更新逻辑
    assign next_pc = pc_sel_EX ? (is_jalr_EX ? {alu_out_EX[31:1], 1'b0} : alu_out_EX)
                               : pc_plus_4_IF; // 默认步进取 IF 的 pc_plus_4_IF

    // ========================= EX/MEM Pipeline Register =========================
    wire [31:0] pc_MEM, inst_MEM, pc_plus_4_MEM, alu_out_MEM, rf_rdata2_MEM;
    wire        commit_MEM;
    wire [4:0]  rd_MEM;
    wire        rf_we_MEM, mem_write_MEM, mem_read_MEM, halt_MEM;
    wire [1:0]  wb_sel_MEM;
    wire [6:0]  opcode_MEM;
    wire [2:0]  funct3_MEM;

    seg_reg ex_mem_reg (
        .clk(clk), .rst(rst), .en(global_en), .stall(stall), .flush(flush),
        .pc_in(pc_EX), .inst_in(inst_EX), .pc_plus_4_in(pc_plus_4_EX), .commit_in(commit_EX),
        .rd_in(rd_EX), .rf_rdata2_in(forwarded_rdata2_EX), .alu_out_in(alu_out_EX),
        .rf_we_in(rf_we_EX), .wb_sel_in(wb_sel_EX), .mem_write_in(mem_write_EX), .mem_read_in(mem_read_EX), .halt_in(halt_EX),
        .opcode_in(opcode_EX), .funct3_in(funct3_EX),

        .pc_out(pc_MEM), .inst_out(inst_MEM), .pc_plus_4_out(pc_plus_4_MEM), .commit_out(commit_MEM),
        .rd_out(rd_MEM), .rf_rdata2_out(rf_rdata2_MEM), .alu_out_out(alu_out_MEM),
        .rf_we_out(rf_we_MEM), .wb_sel_out(wb_sel_MEM), .mem_write_out(mem_write_MEM), .mem_read_out(mem_read_MEM), .halt_out(halt_MEM),
        .opcode_out(opcode_MEM), .funct3_out(funct3_MEM),
        // unused
        .rs1_in(5'b0), .rs2_in(5'b0), .imm_in(32'b0), .rf_rdata1_in(32'b0), .pc_sel_in(1'b0), .alu_src_a_in(1'b0), .alu_src_b_in(1'b0),
        .alu_op_in(5'b0), .cmp_op_in(3'b0), .is_jalr_in(1'b0), .funct7_in(7'b0), .cmp_res_in(1'b0), .mem_read_data_in(32'b0),
        .rs1_out(), .rs2_out(), .imm_out(), .rf_rdata1_out(), .pc_sel_out(), .alu_src_a_out(), .alu_src_b_out(),
        .alu_op_out(), .cmp_op_out(), .is_jalr_out(), .funct7_out(), .cmp_res_out(), .mem_read_data_out()
    );

    // ========================= MEM Stage =========================
    // 本阶段主要处理数据存储器的读写逻辑，处理数据的字、半字、字节对齐及符号扩展
    // 对于非访存指令，本部分透传
    // 产生的主要信号和数据：数据内存访存数据与控制信号 dmem_wdata/dmem_we/dmem_addr，读取后的结果 mem_read_data_processed_MEM
    wire [31:0] mem_read_data_processed_MEM;
    wire [31:0] ctrl_wdata_MEM;
    wire [ 3:0] ctrl_we_mask_MEM;

    data_mem_ctrl u_data_mem_ctrl (
        .addr       (alu_out_MEM),
        .funct3     (funct3_MEM),
        .mem_write  (mem_write_MEM),
        .mem_read   (mem_read_MEM),
        .wdata_in   (rf_rdata2_MEM),
        .rdata_in   (dmem_rdata),
        .wdata_out  (ctrl_wdata_MEM),
        .we_mask    (ctrl_we_mask_MEM),
        .rdata_out  (mem_read_data_processed_MEM)
    );

    // 数据存储器地址字对齐（低 2 位清零）
    assign dmem_addr = {alu_out_MEM[31:2], 2'b00};
    assign dmem_wdata = ctrl_wdata_MEM;
    assign dmem_we = mem_write_MEM && (|ctrl_we_mask_MEM) && global_en;

    // ========================= MEM/WB Pipeline Register =========================
    wire [31:0] pc_WB, inst_WB, pc_plus_4_WB, alu_out_WB, mem_read_data_WB;
    wire        commit_WB;
    wire [1:0]  wb_sel_WB;
    wire        halt_WB;
    wire        mem_write_WB;
    wire [3:0]  ctrl_we_mask_WB;   // 为生成 debug_commit_dmem_we 信号，需要把访存掩码一并传递以判断是否发生了内存写入
    wire [31:0] dmem_addr_WB;
    wire [31:0] dmem_wdata_WB;

    seg_reg mem_wb_reg (
        .clk(clk), .rst(rst), .en(global_en), .stall(stall), .flush(flush),
        .pc_in(pc_MEM), .inst_in(inst_MEM), .pc_plus_4_in(pc_plus_4_MEM), .commit_in(commit_MEM),
        .rd_in(rd_MEM), .alu_out_in(alu_out_MEM), .mem_read_data_in(mem_read_data_processed_MEM),
        .rf_we_in(rf_we_MEM), .wb_sel_in(wb_sel_MEM), .halt_in(halt_MEM),

        .pc_out(pc_WB), .inst_out(inst_WB), .pc_plus_4_out(pc_plus_4_WB), .commit_out(commit_WB),
        .rd_out(rd_WB), .alu_out_out(alu_out_WB), .mem_read_data_out(mem_read_data_WB),
        .rf_we_out(rf_we_WB), .wb_sel_out(wb_sel_WB), .halt_out(halt_WB),
        // unused
        .rs1_in(5'b0), .rs2_in(5'b0), .imm_in(32'b0), .rf_rdata1_in(32'b0), .rf_rdata2_in(32'b0),
        .pc_sel_in(1'b0), .alu_src_a_in(1'b0), .alu_src_b_in(1'b0), .alu_op_in(5'b0), .cmp_op_in(3'b0),
        .mem_write_in(1'b0), .mem_read_in(1'b0), .is_jalr_in(1'b0), .opcode_in(7'b0), .funct3_in(3'b0), .funct7_in(7'b0), .cmp_res_in(1'b0),
        .rs1_out(), .rs2_out(), .imm_out(), .rf_rdata1_out(), .rf_rdata2_out(),
        .pc_sel_out(), .alu_src_a_out(), .alu_src_b_out(), .alu_op_out(), .cmp_op_out(),
        .mem_write_out(), .mem_read_out(), .is_jalr_out(), .opcode_out(), .funct3_out(), .funct7_out(), .cmp_res_out()
    );

    // ========================= WB Stage =========================
    // 本阶段主要选择并确定需要写回寄存器堆的数据
    // 产生的主要信号和数据：最终要写回寄存器的数据 rf_wdata_WB，同时在这里收集调试用的 commit 信号
    assign rf_wdata_WB = (wb_sel_WB == 2'b00) ? alu_out_WB :
                         (wb_sel_WB == 2'b01) ? mem_read_data_WB :
                         (wb_sel_WB == 2'b10) ? pc_plus_4_WB : 32'b0;

    reg commit_dmem_we_r;
    reg [31:0] commit_dmem_wa_r;
    reg [31:0] commit_dmem_wd_r;
    always @(posedge clk) begin
        if (rst) begin
            commit_dmem_we_r <= 1'b0;
            commit_dmem_wa_r <= 32'b0;
            commit_dmem_wd_r <= 32'b0;
        end
        else if (global_en && !stall) begin
            commit_dmem_we_r <= mem_write_MEM && (|ctrl_we_mask_MEM);
            commit_dmem_wa_r <= (mem_read_MEM || mem_write_MEM) ? dmem_addr : `DATA_MEM_START;
            commit_dmem_wd_r <= (mem_write_MEM && (|ctrl_we_mask_MEM)) ? dmem_wdata : 32'b0;
        end
    end

    // ========================= Commit（调试信号） =========================
    reg  [ 0 : 0]   commit_reg          ;
    reg  [31 : 0]   commit_pc_reg       ;
    reg  [31 : 0]   commit_instr_reg    ;
    reg  [ 0 : 0]   commit_halt_reg     ;
    reg  [ 0 : 0]   commit_reg_we_reg   ;
    reg  [ 4 : 0]   commit_reg_wa_reg   ;
    reg  [31 : 0]   commit_reg_wd_reg   ;
    reg  [ 0 : 0]   commit_dmem_we_reg  ;
    reg  [31 : 0]   commit_dmem_wa_reg  ;
    reg  [31 : 0]   commit_dmem_wd_reg  ;

    // 各个 commit 信号输出跟随 WB 段后结果
    always @(posedge clk) begin
        if (rst) begin
            commit_reg          <= 1'b0;
            commit_pc_reg       <= 32'b0;
            commit_instr_reg    <= 32'b0;
            commit_halt_reg     <= 1'b0;
            commit_reg_we_reg   <= 1'b0;
            commit_reg_wa_reg   <= 5'b0;
            commit_reg_wd_reg   <= 32'b0;
            commit_dmem_we_reg  <= 1'b0;
            commit_dmem_wa_reg  <= 32'b0;
            commit_dmem_wd_reg  <= 32'b0;
        end
        else if (global_en) begin
            commit_reg          <= commit_WB;
            commit_pc_reg       <= pc_WB;
            commit_instr_reg    <= inst_WB;
            commit_halt_reg     <= halt_WB;
            commit_reg_we_reg   <= rf_we_WB;
            commit_reg_wa_reg   <= rd_WB;
            commit_reg_wd_reg   <= (rd_WB == 5'b0) ? 32'b0 : rf_wdata_WB;
            commit_dmem_we_reg  <= commit_dmem_we_r;
            commit_dmem_wa_reg  <= commit_dmem_wa_r;
            commit_dmem_wd_reg  <= commit_dmem_wd_r;
        end
        else begin
            commit_reg <= 1'b0;
        end
    end

    assign commit           = commit_reg;
    assign commit_pc        = commit_pc_reg;
    assign commit_instr     = commit_instr_reg;
    assign commit_halt      = commit_halt_reg;
    assign commit_reg_we    = commit_reg_we_reg;
    assign commit_reg_wa    = commit_reg_wa_reg;
    assign commit_reg_wd    = commit_reg_wd_reg;
    assign commit_dmem_we   = commit_dmem_we_reg;
    assign commit_dmem_wa   = commit_dmem_wa_reg;
    assign commit_dmem_wd   = commit_dmem_wd_reg;

    // ========================= Forwarding Unit =========================
    wire [1:0] forward_a;   // 00-寄存器堆，01-上一条指令的 ALU 计算结果，10-上两条指令的写回数据
    wire [1:0] forward_b;
    wire [31:0] rf_wdata_MEM;   // MEM 阶段可确定的对寄存器堆的写回值

    // 回顾 wb_sel：00-ALU 运算结果，01-访存结果，10-PC+4
    // 如果 wb_sel 选通 01，则需要通过 stall 信号停顿一拍再前递
    assign rf_wdata_MEM = (wb_sel_MEM == 2'b00) ? alu_out_MEM :
                          (wb_sel_MEM == 2'b10) ? pc_plus_4_MEM : 32'b0;

    // 需要首先检查上一条指令（位于 MEM 阶段）是否对当前指令涉及的寄存器有修改，再检查上两条指令（位于 WB 阶段）
    // 判定条件：有对寄存器堆的写入->不是写入 x0 寄存器->写入的寄存器号与当前指令需要使用的寄存器号匹配
    assign forward_a = (rf_we_MEM && rd_MEM != 5'd0 && rd_MEM == rs1_EX) ? 2'b10 :
                       (rf_we_WB && rd_WB != 5'd0 && rd_WB == rs1_EX) ? 2'b01 : 2'b00;

    assign forward_b = (rf_we_MEM && rd_MEM != 5'd0 && rd_MEM == rs2_EX) ? 2'b10 :
                       (rf_we_WB && rd_WB != 5'd0 && rd_WB == rs2_EX) ? 2'b01 : 2'b00;

    // 利用 forward_a/b 信号选择理论上正确的寄存器端口输出
    assign forwarded_rdata1_EX = (forward_a == 2'b10) ? rf_wdata_MEM :
                                 (forward_a == 2'b01) ? rf_wdata_WB  :
                                 rf_rdata1_EX;

    assign forwarded_rdata2_EX = (forward_b == 2'b10) ? rf_wdata_MEM :
                                 (forward_b == 2'b01) ? rf_wdata_WB  :
                                 rf_rdata2_EX;

    assign forwarded_rf_rdata1_ID = (rf_we_WB && rd_WB != 5'd0 && rs1_ID == rd_WB) ? 
                                    rf_wdata_WB : rf_rdata1_ID;
    
    assign forwarded_rf_rdata2_ID = (rf_we_WB && rd_WB != 5'd0 && rs2_ID == rd_WB) ? 
                                    rf_wdata_WB : rf_rdata2_ID;
                                 
    // ========================= Hazard Detection Unit =========================
    
    // BRANCH 和 STORE 指令虽然 alu_src 信号标记为使用 PC/imm，
    // 但它们仍需读取 rs1/rs2 的值（BRANCH 用于比较，STORE 的 rs2 用于写入数据）
    wire is_branch_ID = (opcode_ID == 7'b1100011);
    wire is_store_ID  = (opcode_ID == 7'b0100011);

    // 冒险检测：当前位于 EX(3) 阶段的指令将要读内存，且读出的值要存入的寄存器就是 ID(2) 阶段指令要读取的寄存器
    wire load_use_hazard = mem_read_EX && (rd_EX != 5'd0) 
                       && ((rd_EX == rs1_ID && (!alu_src_a_ID || is_branch_ID))
                       ||  (rd_EX == rs2_ID && (!alu_src_b_ID || is_branch_ID || is_store_ID)));
    
    // 如果当前指令需要跳转（pc_sel_EX = 1），就需要刷新取错的指令
    wire control_hazard = pc_sel_EX;

    // 流水线冒险控制信号
    wire pc_stall    = load_use_hazard;
    wire if_id_stall = load_use_hazard;
    wire if_id_flush = control_hazard;
    wire id_ex_flush = load_use_hazard || control_hazard;
    
    wire stall = 1'b0;
    wire flush = 1'b0;

endmodule