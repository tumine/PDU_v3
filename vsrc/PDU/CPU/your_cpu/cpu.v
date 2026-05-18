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
    input                   [ 0 : 0]            cache_flush,

/* ------------------------------ Memory (inst) ----------------------------- */
    output                  [31 : 0]            imem_raddr,
    input                   [31 : 0]            imem_rdata,

/* -------------------------- Memory (data cache) -------------------------- */
    output                  [ 0 : 0]            dmem_mem_r,
    output                  [ 0 : 0]            dmem_mem_w,
    output                  [31 : 0]            dmem_mem_addr,
    output                  [127: 0]            dmem_mem_wdata,
    input                   [127: 0]            dmem_mem_rdata,
    input                   [ 0 : 0]            dmem_mem_ready,

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
    // 五级流水线：IF -> ID -> EX -> MEM -> WB。
    // 本文件的主要改动是让 MEM 阶段经由数据 Cache 访问后端 DMEM，
    // 并把 Cache ready 转换成全流水线冻结信号，保证 miss 等待期间所有段寄存器保持不变。

    wire dcache_wait;
    wire pc_stall;
    wire if_id_stall;
    wire if_id_flush;
    wire id_ex_stall;
    wire id_ex_flush;
    wire ex_mem_stall;
    wire mem_wb_stall;
    wire commit_advance;
    wire bp_redirect_valid;
    wire [31:0] bp_redirect_pc;
    wire [31:0] bp_meta_IF;
    wire [31:0] bp_meta_ID;
    wire [31:0] bp_meta_EX;
    wire [31:0] pc_EX;
    wire [31:0] pc_plus_4_EX;
    wire        commit_EX;
    wire        is_branch_EX;
    wire        is_jal_EX;
    wire        is_jalr_EX;
    wire        actual_taken_EX;
    wire [31:0] actual_target_EX;

    // ========================= IF Stage =========================
    wire [31:0] next_pc;
    wire [31:0] pc_IF;

    reg [31:0] pc_reg;
    always @(posedge clk) begin
        if (rst) begin
            pc_reg <= `INSTR_MEM_START;
        end
        else if (global_en && !pc_stall) begin
            // Cache miss 或 load-use 冒险时保持 PC，不发出新的取指地址。
            pc_reg <= next_pc;
        end
    end

    assign pc_IF = pc_reg;
    assign imem_raddr = pc_IF;

    wire        imem_out_bounds = (pc_IF < `INSTR_MEM_START)
                               || (pc_IF >= `INSTR_MEM_START + (1 << (`INSTR_MEM_DEPTH + 2)));
    wire [31:0] inst_IF = imem_out_bounds ? 32'h00000013 : imem_rdata; // 越界取指时执行 NOP(addi x0,x0,0)
    wire [31:0] pc_plus_4_IF = pc_IF + 32'd4;
    wire        commit_IF = 1'b1;
    wire        bp_pred_valid_IF;
    wire        bp_pred_taken_IF;
    wire [31:0] bp_pred_target_IF;
    wire [31:0] bp_next_pc_IF = (bp_pred_valid_IF && bp_pred_taken_IF) ? bp_pred_target_IF : pc_plus_4_IF;

    branch_predictor u_branch_predictor (
        .clk              (clk),
        .rst              (rst),
        .en               (global_en),
        .stall            (dcache_wait),
        .if_pc            (pc_IF),
        .if_inst          (inst_IF),
        .if_pred_valid    (bp_pred_valid_IF),
        .if_pred_taken    (bp_pred_taken_IF),
        .if_pred_target   (bp_pred_target_IF),
        .if_pred_meta     (bp_meta_IF),
        .ex_valid         (commit_EX),
        .ex_pc            (pc_EX),
        .ex_pc_plus4      (pc_plus_4_EX),
        .ex_target_actual (actual_target_EX),
        .ex_taken_actual  (actual_taken_EX),
        .ex_is_branch     (is_branch_EX),
        .ex_is_jal        (is_jal_EX),
        .ex_is_jalr       (is_jalr_EX),
        .ex_meta          (bp_meta_EX),
        .redirect_valid   (bp_redirect_valid),
        .redirect_pc      (bp_redirect_pc)
    );

    // ========================= IF/ID Pipeline Register =========================
    wire [31:0] pc_ID, inst_ID, pc_plus_4_ID;
    wire        commit_ID;

    pipe_reg #(.WIDTH(32)) if_id_bp_meta_reg (
        .clk(clk), .rst(rst), .en(global_en), .stall(if_id_stall), .flush(if_id_flush),
        .data_in(bp_meta_IF), .data_out(bp_meta_ID)
    );

    seg_reg if_id_reg (
        .clk(clk), .rst(rst), .en(global_en), .stall(if_id_stall), .flush(if_id_flush),
        .pc_in(pc_IF), .inst_in(inst_IF), .pc_plus_4_in(pc_plus_4_IF), .commit_in(commit_IF),
        .pc_out(pc_ID), .inst_out(inst_ID), .pc_plus_4_out(pc_plus_4_ID), .commit_out(commit_ID),
        // unused signals
        .rs1_in(5'b0), .rs2_in(5'b0), .rd_in(5'b0), .imm_in(32'b0), .rf_rdata1_in(32'b0), .rf_rdata2_in(32'b0),
        .pc_sel_in(1'b0), .rf_we_in(1'b0), .wb_sel_in(2'b0), .alu_src_a_in(1'b0), .alu_src_b_in(1'b0),
        .alu_op_in(4'b0), .cmp_op_in(3'b0), .mem_write_in(1'b0), .mem_read_in(1'b0), .is_jalr_in(1'b0), .halt_in(1'b0),
        .opcode_in(7'b0), .funct3_in(3'b0), .funct7_in(7'b0), .cmp_res_in(1'b0), .alu_out_in(32'b0), .mem_read_data_in(32'b0),
        .rs1_out(), .rs2_out(), .rd_out(), .imm_out(), .rf_rdata1_out(), .rf_rdata2_out(),
        .pc_sel_out(), .rf_we_out(), .wb_sel_out(), .alu_src_a_out(), .alu_src_b_out(),
        .alu_op_out(), .cmp_op_out(), .mem_write_out(), .mem_read_out(), .is_jalr_out(), .halt_out(),
        .opcode_out(), .funct3_out(), .funct7_out(), .cmp_res_out(), .alu_out_out(), .mem_read_data_out()
    );

    // ========================= ID Stage =========================
    wire [4:0]  rs1_ID     = inst_ID[19:15];
    wire [4:0]  rs2_ID     = inst_ID[24:20];
    wire [4:0]  rd_ID      = inst_ID[11:7];
    wire [2:0]  funct3_ID  = inst_ID[14:12];
    wire [6:0]  funct7_ID  = inst_ID[31:25];
    wire [6:0]  opcode_ID  = inst_ID[6:0];
    wire [31:0] imm_ID;

    wire [31:0] rf_rdata1_ID, rf_rdata2_ID;
    wire [31:0] forwarded_rf_rdata1_ID, forwarded_rf_rdata2_ID;

    wire        rf_we_WB;
    wire [4:0]  rd_WB;
    wire [31:0] rf_wdata_WB;

    regfile u_regfile (
        .clk        (clk),
        // Cache 等待期间 WB 段保持不变，写使能也必须冻结，否则同一条指令会重复写寄存器堆。
        .we         (rf_we_WB && global_en && !dcache_wait),
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

    wire        rf_we_ID;
    wire [1:0]  wb_sel_ID;
    wire        alu_src_a_ID;
    wire        alu_src_b_ID;
    // RV32M 裁剪后 ALU 仅保留 RV32I 基础操作，4 位控制码即可覆盖，减少流水线控制位宽。
    wire [3:0]  alu_op_ID;
    wire [2:0]  cmp_op_ID;
    wire        mem_write_ID;
    wire        mem_read_ID;
    wire        is_jalr_ID;
    wire        halt_ID;

    decoder u_decoder (
        .opcode     (opcode_ID),
        .funct3     (funct3_ID),
        .funct7     (funct7_ID),
        .cmp_res    (1'b0),
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
    wire [31:0] inst_EX;
    wire [4:0]  rs1_EX, rs2_EX, rd_EX;
    wire [31:0] imm_EX, rf_rdata1_EX, rf_rdata2_EX;
    wire        rf_we_EX, alu_src_a_EX, alu_src_b_EX, mem_write_EX, mem_read_EX, halt_EX;
    wire [1:0]  wb_sel_EX;
    wire [3:0]  alu_op_EX;
    wire [2:0]  cmp_op_EX;
    wire [6:0]  opcode_EX;
    wire [2:0]  funct3_EX;
    wire [6:0]  funct7_EX;

    pipe_reg #(.WIDTH(32)) id_ex_bp_meta_reg (
        .clk(clk), .rst(rst), .en(global_en), .stall(id_ex_stall), .flush(id_ex_flush),
        .data_in(bp_meta_ID), .data_out(bp_meta_EX)
    );

    seg_reg id_ex_reg (
        .clk(clk), .rst(rst), .en(global_en), .stall(id_ex_stall), .flush(id_ex_flush),
        .pc_in(pc_ID), .inst_in(inst_ID), .pc_plus_4_in(pc_plus_4_ID), .commit_in(commit_ID),
        .rs1_in(rs1_ID), .rs2_in(rs2_ID), .rd_in(rd_ID), .imm_in(imm_ID),
        .rf_rdata1_in(forwarded_rf_rdata1_ID), .rf_rdata2_in(forwarded_rf_rdata2_ID),
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

    assign is_branch_EX = (opcode_EX == 7'b1100011);
    assign is_jal_EX    = (opcode_EX == 7'b1101111);
    assign actual_taken_EX = is_branch_EX ? cmp_res_EX : (is_jal_EX | is_jalr_EX);
    assign actual_target_EX = is_jalr_EX ? {alu_out_EX[31:1], 1'b0} : alu_out_EX;
    wire pc_sel_EX    = actual_taken_EX;

    // EX 阶段给出最终裁决；若预测路径与真实结果不一致，则优先用 redirect_pc 覆盖 IF 的预测值。
    // 这样可以保证错误路径在下一个周期被冲刷，且不会让 IF 继续沿着旧方向推进。
    assign next_pc = bp_redirect_valid ? bp_redirect_pc
                                       : (bp_pred_valid_IF && bp_pred_taken_IF) ? bp_pred_target_IF
                                       : pc_plus_4_IF;

    // ========================= EX/MEM Pipeline Register =========================
    wire [31:0] pc_MEM, inst_MEM, pc_plus_4_MEM, alu_out_MEM, rf_rdata2_MEM;
    wire        commit_MEM;
    wire [4:0]  rd_MEM;
    wire        rf_we_MEM, mem_write_MEM, mem_read_MEM, halt_MEM;
    wire [1:0]  wb_sel_MEM;
    wire [6:0]  opcode_MEM;
    wire [2:0]  funct3_MEM;

    seg_reg ex_mem_reg (
        .clk(clk), .rst(rst), .en(global_en), .stall(ex_mem_stall), .flush(1'b0),
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
        .alu_op_in(4'b0), .cmp_op_in(3'b0), .is_jalr_in(1'b0), .funct7_in(7'b0), .cmp_res_in(1'b0), .mem_read_data_in(32'b0),
        .rs1_out(), .rs2_out(), .imm_out(), .rf_rdata1_out(), .pc_sel_out(), .alu_src_a_out(), .alu_src_b_out(),
        .alu_op_out(), .cmp_op_out(), .is_jalr_out(), .funct7_out(), .cmp_res_out(), .mem_read_data_out()
    );

    // ========================= MEM Stage + Data Cache =========================
    wire [31:0] mem_read_data_processed_MEM;
    wire [31:0] ctrl_wdata_MEM;
    wire [ 3:0] ctrl_we_mask_MEM;
    wire [31:0] dcache_rdata;
    wire        dcache_miss;
    wire        dcache_ready;
    wire        mem_write_effective_MEM = mem_write_MEM && (|ctrl_we_mask_MEM);
    wire        mem_access_MEM = mem_read_MEM || mem_write_effective_MEM;

    data_mem_ctrl u_data_mem_ctrl (
        .addr       (alu_out_MEM),
        .funct3     (funct3_MEM),
        .mem_write  (mem_write_MEM),
        .mem_read   (mem_read_MEM),
        .wdata_in   (rf_rdata2_MEM),
        .rdata_in   (dcache_rdata),
        .wdata_out  (ctrl_wdata_MEM),
        .we_mask    (ctrl_we_mask_MEM),
        .rdata_out  (mem_read_data_processed_MEM)
    );

    reg dcache_req_active;
    wire dcache_req_fire = global_en && mem_access_MEM && !dcache_req_active;
    wire dcache_r_req = dcache_req_fire && mem_read_MEM;
    wire dcache_w_req = dcache_req_fire && mem_write_effective_MEM;

    always @(posedge clk) begin
        if (rst) begin
            dcache_req_active <= 1'b0;
        end
        else if (!global_en) begin
            dcache_req_active <= 1'b0;
        end
        else if (!mem_access_MEM) begin
            dcache_req_active <= 1'b0;
        end
        else if (dcache_ready) begin
            // ready 周期说明本次 load/store 已完成，下一条进入 MEM 的访存可以重新发请求。
            dcache_req_active <= 1'b0;
        end
        else if (dcache_req_fire) begin
            // 首次进入 MEM 的访存指令只发起一次 Cache 请求，随后由 dcache_req_active 维持等待状态。
            dcache_req_active <= 1'b1;
        end
    end

    cache #(
        .ADDR_WIDTH        (32),
        .DATA_WIDTH        (32),
        .INDEX_WIDTH       (3),
        .WAY_NUM           (2),
        // DCache 已固定为纯 LRU 替换策略，删除多策略参数以避免保留无用控制逻辑。
        .LINE_OFFSET_WIDTH (2)
    ) u_dcache (
        .clk        (clk),
        // PDU 调试写 DMEM 完成后显式 flush 数据 Cache。
        // 写直达策略保证 Cache 没有脏行；flush 只用于避免 PDU 修改后端 DMEM 后 CPU 继续命中旧 Cache 行。
        .rstn       (~rst && ~cache_flush),
        .addr       (alu_out_MEM),
        .r_req      (dcache_r_req),
        .w_req      (dcache_w_req),
        .w_data     (ctrl_wdata_MEM),
        .w_mask     (ctrl_we_mask_MEM),
        .r_data     (dcache_rdata),
        .miss       (dcache_miss),
        .ready      (dcache_ready),
        .mem_r      (dmem_mem_r),
        .mem_w      (dmem_mem_w),
        .mem_addr   (dmem_mem_addr),
        .mem_w_data (dmem_mem_wdata),
        .mem_r_data (dmem_mem_rdata),
        .mem_ready  (dmem_mem_ready)
    );

    assign dcache_wait = mem_access_MEM && (dcache_req_fire || dcache_req_active || dcache_miss) && !dcache_ready;

    // ========================= MEM/WB Pipeline Register =========================
    wire [31:0] pc_WB, inst_WB, pc_plus_4_WB, alu_out_WB, mem_read_data_WB;
    wire        commit_WB;
    wire [1:0]  wb_sel_WB;
    wire        halt_WB;

    seg_reg mem_wb_reg (
        .clk(clk), .rst(rst), .en(global_en), .stall(mem_wb_stall), .flush(1'b0),
        .pc_in(pc_MEM), .inst_in(inst_MEM), .pc_plus_4_in(pc_plus_4_MEM), .commit_in(commit_MEM),
        .rd_in(rd_MEM), .alu_out_in(alu_out_MEM), .mem_read_data_in(mem_read_data_processed_MEM),
        .rf_we_in(rf_we_MEM), .wb_sel_in(wb_sel_MEM), .halt_in(halt_MEM),
        .pc_out(pc_WB), .inst_out(inst_WB), .pc_plus_4_out(pc_plus_4_WB), .commit_out(commit_WB),
        .rd_out(rd_WB), .alu_out_out(alu_out_WB), .mem_read_data_out(mem_read_data_WB),
        .rf_we_out(rf_we_WB), .wb_sel_out(wb_sel_WB), .halt_out(halt_WB),
        // unused
        .rs1_in(5'b0), .rs2_in(5'b0), .imm_in(32'b0), .rf_rdata1_in(32'b0), .rf_rdata2_in(32'b0),
        .pc_sel_in(1'b0), .alu_src_a_in(1'b0), .alu_src_b_in(1'b0), .alu_op_in(4'b0), .cmp_op_in(3'b0),
        .mem_write_in(1'b0), .mem_read_in(1'b0), .is_jalr_in(1'b0), .opcode_in(7'b0), .funct3_in(3'b0), .funct7_in(7'b0), .cmp_res_in(1'b0),
        .rs1_out(), .rs2_out(), .imm_out(), .rf_rdata1_out(), .rf_rdata2_out(),
        .pc_sel_out(), .alu_src_a_out(), .alu_src_b_out(), .alu_op_out(), .cmp_op_out(),
        .mem_write_out(), .mem_read_out(), .is_jalr_out(), .opcode_out(), .funct3_out(), .funct7_out(), .cmp_res_out()
    );

    // ========================= WB Stage =========================
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
        else if (global_en && !dcache_wait) begin
            // 只有 Cache 事务完成并允许流水线前进时，才采样本条 MEM 指令的调试访存信息。
            commit_dmem_we_r <= mem_write_effective_MEM;
            commit_dmem_wa_r <= mem_access_MEM ? {alu_out_MEM[31:2], 2'b00} : `DATA_MEM_START;
            commit_dmem_wd_r <= mem_write_effective_MEM ? ctrl_wdata_MEM : 32'b0;
        end
    end

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

    assign commit_advance = global_en && !dcache_wait;

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
        else if (commit_advance) begin
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
            // Cache miss 或 PDU 暂停期间不产生新的 commit 脉冲。
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
    wire [1:0] forward_a;
    wire [1:0] forward_b;
    wire [31:0] rf_wdata_MEM;

    assign rf_wdata_MEM = (wb_sel_MEM == 2'b00) ? alu_out_MEM :
                          (wb_sel_MEM == 2'b10) ? pc_plus_4_MEM : 32'b0;

    assign forward_a = (rf_we_MEM && rd_MEM != 5'd0 && rd_MEM == rs1_EX) ? 2'b10 :
                       (rf_we_WB  && rd_WB  != 5'd0 && rd_WB  == rs1_EX) ? 2'b01 : 2'b00;
    assign forward_b = (rf_we_MEM && rd_MEM != 5'd0 && rd_MEM == rs2_EX) ? 2'b10 :
                       (rf_we_WB  && rd_WB  != 5'd0 && rd_WB  == rs2_EX) ? 2'b01 : 2'b00;

    assign forwarded_rdata1_EX = (forward_a == 2'b10) ? rf_wdata_MEM :
                                 (forward_a == 2'b01) ? rf_wdata_WB  :
                                 rf_rdata1_EX;
    assign forwarded_rdata2_EX = (forward_b == 2'b10) ? rf_wdata_MEM :
                                 (forward_b == 2'b01) ? rf_wdata_WB  :
                                 rf_rdata2_EX;

    assign forwarded_rf_rdata1_ID =
        (rf_we_WB && rd_WB != 5'd0 && rs1_ID == rd_WB) ? rf_wdata_WB : rf_rdata1_ID;
    assign forwarded_rf_rdata2_ID =
        (rf_we_WB && rd_WB != 5'd0 && rs2_ID == rd_WB) ? rf_wdata_WB : rf_rdata2_ID;

    // ========================= Hazard Detection Unit =========================
    wire is_branch_ID = (opcode_ID == 7'b1100011);
    wire is_store_ID  = (opcode_ID == 7'b0100011);

    wire load_use_hazard = mem_read_EX && (rd_EX != 5'd0)
                       && ((rd_EX == rs1_ID && (!alu_src_a_ID || is_branch_ID))
                       ||  (rd_EX == rs2_ID && (!alu_src_b_ID || is_branch_ID || is_store_ID)));

    wire control_hazard = bp_redirect_valid;

    // Cache 等待优先级最高：等待期间所有段寄存器保持原值，不能执行 flush。
    assign pc_stall    = load_use_hazard || dcache_wait;
    assign if_id_stall = load_use_hazard || dcache_wait;
    assign id_ex_stall = dcache_wait;
    assign ex_mem_stall = dcache_wait;
    assign mem_wb_stall = dcache_wait;

    assign if_id_flush = (!dcache_wait) && control_hazard;
    assign id_ex_flush = (!dcache_wait) && (load_use_hazard || control_hazard);

endmodule
