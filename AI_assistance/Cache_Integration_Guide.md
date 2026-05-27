# 数据 Cache 接入 CPU 详细指南

## 目录

1. [接入前后架构对比](#1-接入前后架构对比)
2. [总体设计思路](#2-总体设计思路)
3. [Cache 模块详解](#3-cache-模块详解)
4. [data_mem_ctrl 改造](#4-data_mem_ctrl-改造)
5. [CPU 改造：MEM 阶段与流水线冻结](#5-cpu-改造mem-阶段与流水线冻结)
6. [DMEM 改造：零延迟存储器变为事务接口](#6-dmem-改造零延迟存储器变为事务接口)
7. [MEM_ARBITER 改造：双主仲裁](#7-mem_arbiter-改造双主仲裁)
8. [TOP 改造：跨时钟域与 Cache Flush](#8-top-改造跨时钟域与-cache-flush)
9. [CPU_ctrl 改造：调试请求等待](#9-cpu_ctrl-改造调试请求等待)
10. [分步接入流程](#10-分步接入流程)
11. [常见问题与注意事项](#11-常见问题与注意事项)

---

## 1. 接入前后架构对比

### 1.1 接入前（无 Cache）

```
CPU MEM 阶段 ──[32位 addr/wdata/rdata/we]──> DMEM（零延迟组合读写）
                                                    │
CPU_ctrl（PDU 调试）──[32位 addr/wdata/rdata/we]──>┘
```

- CPU 对 DMEM 的 load/store **零延迟**完成，每条访存指令在 MEM 阶段只需要一个周期。
- PDU 调试读写也直接访问同一块 DMEM，无仲裁延迟。
- `data_mem_ctrl` 在 store 时需要先读 DMEM 旧值再按字节掩码合并写回。

### 1.2 接入后（带 Cache）

```
CPU MEM 阶段 ──[data_mem_ctrl]──> Data Cache ──[128位 Cache Line 事务]──> MEM_ARBITER ──> DMEM（带延迟事务接口）
                                                                                          │
CPU_ctrl（PDU 调试）────────────────────────────────────────────────────────────────────>┘
```

- CPU 访存经过 **数据 Cache**，命中时一个周期完成，miss 时需要等待后端 DMEM 返回整条 Cache Line。
- DMEM 从零延迟改为带 `req/ready` 的事务接口，支持 128 位整行读写（Cache Line）和 32 位调试字读写。
- PDU 调试通过 `MEM_ARBITER` 在 CPU 停止时独占 DMEM。
- Cache miss 期间**冻结整条流水线**，所有段寄存器保持不变。

---

## 2. 总体设计思路

### 2.1 核心原则

| 原则 | 说明 |
|------|------|
| 写直达 + 写分配 | 每次 store 无论命中与否都同时写入 Cache 和后端 DMEM，保证 PDU 停机后读取 DMEM 能看到最新数据 |
| 全流水线冻结 | Cache miss 时冻结 PC、IF/ID、ID/EX、EX/MEM、MEM/WB 全部段寄存器，简化控制逻辑 |
| 阻塞式握手 | CPU 发出访存请求后保持等待，Cache 返回 `ready` 后流水线才继续前进 |
| Cache Line 一致性 | PDU 调试写 DMEM 后发出 `cache_flush`，清空全部 Cache 行避免命中旧数据 |

### 2.2 关键信号流

```
                    ┌───────────────┐
  alu_out_MEM ─────>│ data_mem_ctrl │──── ctrl_wdata_MEM ────> Cache.w_data
  funct3_MEM ──────>│               │──── ctrl_we_mask_MEM ──> Cache.w_mask
  mem_write_MEM ───>│               │<─── dcache_rdata <──── Cache.r_data
  mem_read_MEM ────>│               │──── rdata_out ────────> MEM/WB 段寄存器
  rf_rdata2_MEM ───>│               │
                    └───────────────┘
                            │
                    ┌───────┴───────┐
                    │  Data Cache   │
                    │  (n_way_cache)│
                    └───────┬───────┘
                            │ miss/ready
                    ┌───────┴───────┐
                    │ dcache_wait ──>│ 全流水线 stall
                    │ dcache_req_active ──> 防止重复发请求
                    └───────────────┘
```

---

## 3. Cache 模块详解

### 3.1 模块参数

```verilog
module cache #(
    parameter ADDR_WIDTH        = 32,   // 物理地址位宽
    parameter DATA_WIDTH        = 32,   // CPU 侧一次 load/store 的字宽
    parameter INDEX_WIDTH       = 3,    // Cache set 索引位宽，set 数 = 2^3 = 8
    parameter WAY_NUM           = 2,    // 组相联路数
    parameter LINE_OFFSET_WIDTH = 2     // 每条 Cache Line 包含 2^2 = 4 个字 (128 位)
)
```

**地址划分**（以当前参数为例）：

| 字段 | 位范围 | 位宽 | 说明 |
|------|--------|------|------|
| Tag | [31:7] | 25 | 标识不同 Cache Line |
| Index | [6:4] | 3 | 选择 8 个 Cache 组 |
| Word Offset | [3:2] | 2 | 选择 Cache Line 内的 4 个字 |
| Byte Offset | [1:0] | 2 | 字内字节偏移 |

### 3.2 CPU 侧接口

```verilog
// CPU 侧请求接口
input  [31:0]  addr,       // CPU 访存字节地址
input          r_req,      // load 请求（仅 Cache 空闲时采样一次）
input          w_req,      // store 请求（仅 Cache 空闲时采样一次）
input  [31:0]  w_data,     // store 数据（已由 data_mem_ctrl 复制到目标字节通道）
input  [ 3:0]  w_mask,     // store 字节写掩码
output [31:0]  r_data,     // load 返回的 32 位原始字
output         miss,       // Cache 正在阻塞 CPU
output         ready       // 本次访存完成
```

**关键语义**：
- `r_req`/`w_req` 只需维持一个周期，Cache 在 `STATE_IDLE` 态采样后锁存。
- `ready` 拉高一个周期表示本次访存事务完成，CPU 可以解除流水线冻结。
- `r_data` 在 `ready` 有效的周期给出正确的 load 数据。

### 3.3 后端主存接口

```verilog
// 后端主存接口（128 位 Cache Line 粒度）
output         mem_r,      // 向主存发起整行读取请求
output         mem_w,      // 向主存发起整行写入请求
output [31:0]  mem_addr,   // Cache Line 基地址
output [127:0] mem_w_data, // 写回主存的完整 Cache Line
input  [127:0] mem_r_data, // 主存返回的完整 Cache Line
input          mem_ready   // 主存事务完成脉冲
```

### 3.4 状态机

```
         r_req/w_req
  IDLE ──────────────> LOOKUP
                         │
              ┌──────────┴──────────┐
              │ hit                  │ miss
              v                      v
        hit & load:           MISS_READ
        ready=1,回IDLE      (等待mem_ready)
              │                      │
        hit & store:                v
        写Cache              REFILL
        ──> W_THROUGH        (写Cache行到
              │                选中的way)
              v                      │
         W_THROUGH            store miss:
        (写直达DMEM)          ──> W_THROUGH
        等待mem_ready               │
              │                      │
              v                      v
           IDLE <─────────────── IDLE
```

| 状态 | 说明 | CPU 视角 |
|------|------|----------|
| `STATE_IDLE` | 空闲，等待请求 | 不阻塞 |
| `STATE_LOOKUP` | 查 Tag，判断命中/miss | 阻塞（miss=1） |
| `STATE_MISS_READ` | 向后端 DMEM 发整行读请求 | 阻塞 |
| `STATE_REFILL` | 把 DMEM 返回行写入 Cache | load miss 时 ready=1 |
| `STATE_W_THROUGH` | 把更新后的 Cache Line 写直达 DMEM | store 时阻塞到写完 |

### 3.5 替换策略

当前实现采用纯 **LRU（最近最少使用）** 替换策略：

- 每个 Cache 组维护一个 `lru_age[set][way]` 矩阵。
- 命中或换入的 way 年龄清零，其余更年轻的 way 年龄 +1。
- 替换时优先选择 invalid way；全 valid 时选择 `lru_age == WAY_NUM-1` 的 way。

### 3.6 Store 合并机制

`merge_store_word` 函数在 Cache Line 内完成字节级合并：

```verilog
// data_mem_ctrl 已经把 SB/SH 的数据复制到对应字节通道
// Cache 只需按 w_mask 逐字节选择替换
function [LINE_WIDTH-1:0] merge_store_word;
    input [LINE_WIDTH-1:0] old_line;    // 旧 Cache Line 数据
    input [LINE_OFFSET_WIDTH-1:0] offset; // 字偏移
    input [DATA_WIDTH-1:0] word_data;    // 新 store 数据
    input [3:0] byte_mask;               // 字节写掩码
```

### 3.7 BRAM 模块

```verilog
module bram #(
    parameter ADDR_WIDTH = 4,
    parameter DATA_WIDTH = 32
)(
    input              clk, rstn,
    input [ADDR_WIDTH-1:0] raddr, waddr,
    input [DATA_WIDTH-1:0] din,
    input              we,
    output [DATA_WIDTH-1:0] dout
);
```

- **组合读**：`dout = mem[raddr]`，保证 LOOKUP 状态内可直接得到 Tag/Data。
- **同步写**：`mem[waddr] <= din`，在时钟沿提交。
- **复位清零**：`rstn` 低电平时同步清空所有 RAM，使 Tag 的 valid 位默认无效。

---

## 4. data_mem_ctrl 改造

### 4.1 改造原因

接入 Cache 前，`data_mem_ctrl`（原 `data_mem_ctrl`）的 store 路径依赖**零延迟读旧值再合并**：

```verilog
// 旧实现（不适用）
case (funct3)
    3'b000: wdata_out = (rdata_in & ~byte_mask) | (wdata_in_shifted & byte_mask);
endcase
```

接入 Cache 后，Cache 命中时返回的是 Cache Line 中的对齐 32 位字，但 miss 期间数据不可用。更重要的是，Cache 的合并操作是在 **128 位 Cache Line 粒度**上完成的，`data_mem_ctrl` 只需提供"想写哪些字节"和"新字节值是什么"即可。

### 4.2 新接口

```verilog
module data_mem_ctrl (
    input  wire [31:0] addr,        // ALU 计算出的字节地址
    input  wire [2:0]  funct3,      // load/store 指令的 funct3
    input  wire        mem_write,   // store 有效
    input  wire        mem_read,    // load 有效
    input  wire [31:0] wdata_in,    // store 的原始 rs2 数据
    input  wire [31:0] rdata_in,    // Cache 返回的 32 位对齐字
    output reg  [31:0] wdata_out,   // 已复制到对应字节通道的 store 数据
    output reg  [3:0]  we_mask,     // 字节写掩码，1 表示该字节需要写入
    output reg  [31:0] rdata_out    // load 扩展后的写回数据
);
```

### 4.3 Store 路径改造

```verilog
// SB: 把最低字节复制到四个字节通道，we_mask 决定写哪一个
3'b000: begin
    wdata_out = {4{wdata_in[7:0]}};
    we_mask   = 4'b0001 << offset;
end

// SH: 半字数据复制到高低半字通道
3'b001: begin
    wdata_out = {2{wdata_in[15:0]}};
    we_mask   = offset[0] ? 4'b0000 :    // 非对齐不写
                offset[1] ? 4'b1100 : 4'b0011;
end

// SW: 整字写入，四个字节全部有效
3'b010: begin
    wdata_out = wdata_in;
    we_mask   = 4'b1111;
end
```

**关键变化**：不再依赖 `rdata_in` 旧值合并，合并动作由 Cache 在 Cache Line 内完成。

### 4.4 Load 路径（不变）

Load 路径逻辑保持不变：从 Cache 返回的 32 位对齐字中按 `offset` 和 `funct3` 截取并做符号/零扩展。

---

## 5. CPU 改造：MEM 阶段与流水线冻结

### 5.1 CPU 端口变化

接入 Cache 前：
```verilog
// 旧的 32 位直连 DMEM 接口
output [31:0] dmem_addr,
output [31:0] dmem_wdata,
output        dmem_we,
input  [31:0] dmem_rdata,
```

接入 Cache 后：
```verilog
// 新的 128 位 Cache Line 事务端口
output [ 0:0]  dmem_mem_r,       // Cache 向后端 DMEM 发整行读请求
output [ 0:0]  dmem_mem_w,       // Cache 向后端 DMEM 发整行写请求
output [31:0]  dmem_mem_addr,    // Cache Line 基地址
output [127:0] dmem_mem_wdata,   // 写回 DMEM 的完整 Cache Line
input  [127:0] dmem_mem_rdata,   // DMEM 返回的完整 Cache Line
input  [ 0:0]  dmem_mem_ready,   // DMEM 事务完成脉冲
input  [ 0:0]  cache_flush,      // PDU 调试写后的 Cache flush
```

### 5.2 MEM 阶段例化 Cache

在 `cpu.v` 的 MEM 阶段例化数据 Cache：

```verilog
cache #(
    .ADDR_WIDTH        (32),
    .DATA_WIDTH        (32),
    .INDEX_WIDTH       (3),
    .WAY_NUM           (2),
    .LINE_OFFSET_WIDTH (2)
) u_dcache (
    .clk        (clk),
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
```

### 5.3 请求管理：dcache_req_active

**问题**：Cache miss 期间流水线冻结，MEM 阶段的 `mem_read_MEM`/`mem_write_MEM` 信号会持续保持。如果不加控制，Cache 会在每个周期都看到 `r_req`/`w_req`，导致重复发起请求。

**解决**：引入 `dcache_req_active` 寄存器，确保每条访存指令只发一次请求：

```verilog
reg dcache_req_active;
wire dcache_req_fire = global_en && mem_access_MEM && !dcache_req_active;
wire dcache_r_req = dcache_req_fire && mem_read_MEM;
wire dcache_w_req = dcache_req_fire && mem_write_effective_MEM;

always @(posedge clk) begin
    if (rst)                    dcache_req_active <= 1'b0;
    else if (!global_en)        dcache_req_active <= 1'b0;
    else if (!mem_access_MEM)   dcache_req_active <= 1'b0;
    else if (dcache_ready)      dcache_req_active <= 1'b0;  // 完成后清除
    else if (dcache_req_fire)   dcache_req_active <= 1'b1;  // 首次发起后锁定
end
```

### 5.4 全流水线冻结：dcache_wait

```verilog
// Cache 等待信号：正在访存且尚未完成
assign dcache_wait = mem_access_MEM
                   && (dcache_req_fire || dcache_req_active || dcache_miss)
                   && !dcache_ready;

// 冻结所有段寄存器
assign pc_stall     = load_use_hazard || dcache_wait;
assign if_id_stall  = load_use_hazard || dcache_wait;
assign id_ex_stall  = dcache_wait;
assign ex_mem_stall = dcache_wait;
assign mem_wb_stall = dcache_wait;

// 冲刷信号也要受 dcache_wait 约束
assign if_id_flush = (!dcache_wait) && control_hazard;
assign id_ex_flush = (!dcache_wait) && (load_use_hazard || control_hazard);
```

**为什么全流水线冻结？**

Cache miss 期间 MEM 阶段的数据尚未就绪，后续 WB 阶段无法写回正确结果，因此 EX 及之前的阶段也必须停住。全冻结是最简单且正确的策略，无需处理更复杂的部分前进逻辑。

### 5.5 寄存器堆写回冻结

```verilog
regfile u_regfile (
    .we   (rf_we_WB && global_en && !dcache_wait),  // Cache 等待期间不写寄存器堆
    // ...
);
```

**原因**：如果 `dcache_wait` 期间不冻结 `we`，同一周期的 WB 段寄存器保持不变，但写使能仍然有效，会导致同一条指令重复写入寄存器堆。

### 5.6 commit 调试信息冻结

```verilog
assign commit_advance = global_en && !dcache_wait;

always @(posedge clk) begin
    if (commit_advance) begin
        commit_reg        <= commit_WB;
        commit_pc_reg     <= pc_WB;
        // ... 其他调试信息
    end
    else begin
        commit_reg <= 1'b0;  // Cache miss 期间不产生新 commit 脉冲
    end
end
```

### 5.7 DMEM 写调试信息冻结

```verilog
always @(posedge clk) begin
    if (global_en && !dcache_wait) begin
        // 只有 Cache 事务完成时才采样
        commit_dmem_we_r <= mem_write_effective_MEM;
        commit_dmem_wa_r <= mem_access_MEM ? {alu_out_MEM[31:2], 2'b00} : `DATA_MEM_START;
        commit_dmem_wd_r <= mem_write_effective_MEM ? ctrl_wdata_MEM : 32'b0;
    end
end
```

---

## 6. DMEM 改造：零延迟存储器变为事务接口

### 6.1 接口变化

**旧接口**（零延迟组合读写）：
```verilog
// 直接按地址读写，一个周期完成
input  [DEPTH-1:0] addr,
input  [31:0]      wdata,
input              we,
output [31:0]      rdata,
```

**新接口**（带 `req/ready` 的事务接口）：
```verilog
input  [ 0:0]  req,        // 请求保持信号，请求方必须保持到 ready
input  [ 0:0]  we,         // 1=写事务，0=读事务
input  [ 0:0]  line_mode,  // 1=128位 Cache Line 访问，0=32位调试字访问
input  [DEPTH-1:0] addr,   // 以 32位 word 为单位的地址
output [31:0]   rdata,     // 32位调试读返回
input  [31:0]   wdata,     // 32位调试写数据
output [127:0]  line_rdata, // 128位 Cache Line 读返回
input  [127:0]  line_wdata, // 128位 Cache Line 写数据
output [ 0:0]  ready       // 事务完成脉冲
```

### 6.2 关键设计

**MEM_DELAY 参数**：模拟后端主存延迟（默认 4 个周期），用于验证 Cache 的 miss 处理逻辑。

**Cache Line 访问**：`line_mode=1` 时，DMEM 将 128 位整行访问拆成 4 次单 word 访问，逐字写入/读出 BRAM，适合映射到 FPGA Block RAM。

**FSM 状态**：

```
IDLE ──(req)──> DELAY ──(cnt=0)──> ┬─(write & line_mode)──> LINE_WRITE ──> IDLE
                                    ├─(write & !line_mode)──> IDLE (单拍完成)
                                    └─(read)──> READ_WAIT ──> READ_CAP ──> ┬─(line & last word)──> DONE ──> IDLE
                                                                              └─(word)──> DONE ──> IDLE
                                                                              └─(line & !last)──> READ_WAIT (循环)
```

---

## 7. MEM_ARBITER 改造：双主仲裁

### 7.1 仲裁策略

```
cpu_global_en = 1 (CPU 运行)  →  数据侧选择 Cache Line 请求（128 位）
cpu_global_en = 0 (CPU 停止)  →  数据侧选择 CPU_ctrl 调试请求（32 位）
```

### 7.2 关键连线

```verilog
// 请求选择
assign dmem_req = cpu_global_en ? (cpu_dmem_mem_r | cpu_dmem_mem_w)
                                : (cpu_ctrl_dmem_req & ~dmem_ready);
assign dmem_we  = cpu_global_en ? cpu_dmem_mem_w
                                : cpu_ctrl_dmem_we;
assign dmem_line_mode = cpu_global_en;  // CPU 运行时固定 line_mode=1

// 地址/数据选择
assign dmem_addr       = cpu_global_en ? cpu_dmem_mem_addr : cpu_ctrl_dmem_addr;
assign dmem_line_wdata = cpu_dmem_mem_wdata;

// 返回数据路由
assign cpu_dmem_mem_rdata  = dmem_line_rdata;
assign cpu_dmem_mem_ready  = cpu_global_en ? dmem_ready : 1'b0;  // CPU 停止时 Cache 不应收到 ready
assign cpu_ctrl_dmem_rdata = dmem_rdata;
assign cpu_ctrl_dmem_ready = cpu_global_en ? 1'b0 : dmem_ready;  // CPU 运行时 CPU_ctrl 不应收到 ready
```

**注意**：CPU 停止时 Cache 的 `ready` 被强制置 0，防止 CPU 停止期间 Cache 误收到 DMEM 的响应。

---

## 8. TOP 改造：跨时钟域与 Cache Flush

### 8.1 时钟域关系

```
sys_clk (快)                    cpu_clk (慢，由分频器产生)
  │                                │
  ├─ PDU_kernel                    ├─ CPU (含 Cache)
  ├─ PDU_BUS                       ├─ DMEM
  ├─ PDU_UART                      │
  ├─ CPU_ctrl                      │
  └─ 跨域同步逻辑                   │
```

### 8.2 sys_clk → cpu_clk 同步

PDU 给 CPU 的控制信号（复位、全局使能等）需要从 `sys_clk` 域同步到 `cpu_clk` 域：

```verilog
always @(posedge cpu_clk) begin
    cpu_rst_sync1 <= cpu_rst;
    cpu_rst_sync2 <= cpu_rst_sync1;
    cpu_rst_sync  <= cpu_rst_sync2;        // 两级同步

    cpu_global_en_sync1 <= cpu_global_en;
    cpu_global_en_sync2 <= cpu_global_en_sync1;
    cpu_global_en_sync  <= cpu_global_en_sync2;
end
```

### 8.3 CPU_ctrl 调试请求跨域

CPU_ctrl 在 `sys_clk` 域发出 `dmem_req`，需要传到 `cpu_clk` 域的 DMEM：

```verilog
// 1. 两级同步 req 信号
cpu_ctrl_dmem_req_meta <= cpu_ctrl_dmem_req;
cpu_ctrl_dmem_req_sync <= cpu_ctrl_dmem_req_meta;
cpu_ctrl_dmem_req_prev <= cpu_ctrl_dmem_req_sync;

// 2. 检测上升沿，锁存为一个 pending 事务
wire cpu_ctrl_dmem_req_rise = cpu_ctrl_dmem_req_sync & ~cpu_ctrl_dmem_req_prev;

if (cpu_ctrl_dmem_req_rise && cpu_ctrl_active) begin
    cpu_ctrl_dmem_req_pending <= 1'b1;
    cpu_ctrl_dmem_we_cpu      <= cpu_ctrl_dmem_we;
    cpu_ctrl_dmem_addr_cpu    <= cpu_ctrl_dmem_addr;
    cpu_ctrl_dmem_wdata_cpu   <= cpu_ctrl_dmem_wdata;
end

// 3. DMEM ready 后清除 pending
else if (cpu_ctrl_dmem_ready_cpu) begin
    cpu_ctrl_dmem_req_pending <= 1'b0;
    // 调试写完成后发出 Cache flush
    if (cpu_ctrl_dmem_we_cpu) begin
        cpu_cache_flush_cpu <= 1'b1;
    end
end
```

**为什么不直接连 `req`？** CPU_ctrl 会持续保持 `req` 直到 `ready` 返回。如果直接连接，在 `ready` 同步回 `sys_clk` 之前的多个 `cpu_clk` 周期里，DMEM 可能重复启动新事务。通过上升沿检测 + pending 锁存，保证每次调试访问只启动一次 DMEM 事务。

### 8.4 cpu_clk → sys_clk 同步

DMEM 的 `ready` 和读数据需要从 `cpu_clk` 域同步回 `sys_clk` 域给 CPU_ctrl：

```verilog
always @(posedge sys_clk) begin
    cpu_ctrl_dmem_rdata_sync1 <= cpu_ctrl_dmem_rdata;
    cpu_ctrl_dmem_rdata_sync2 <= cpu_ctrl_dmem_rdata_sync1;
    cpu_ctrl_dmem_ready_sync1 <= cpu_ctrl_dmem_ready_cpu;
    cpu_ctrl_dmem_ready_sync2 <= cpu_ctrl_dmem_ready_sync1;
end

assign cpu_ctrl_dmem_ready_sys = cpu_ctrl_dmem_ready_sync2;
```

### 8.5 Cache Flush 机制

PDU 调试写 DMEM 完成后，后端 DMEM 的数据已经被修改，但 CPU 的 Cache 中可能还缓存着旧数据。为此，在调试写完成后发出一个周期的 `cache_flush`：

```verilog
// TOP.v 中
if (cpu_ctrl_dmem_ready_cpu) begin
    if (cpu_ctrl_dmem_we_cpu) begin
        cpu_cache_flush_cpu <= 1'b1;  // 调试写完成 → flush Cache
    end
end

assign cpu_cache_flush = cpu_cache_flush_cpu;

// CPU 内部
.rstn (~rst && ~cache_flush),  // cache_flush 信号清空全部 Cache RAM
```

**为什么写直达策略还需要 flush？** 写直达保证了 CPU 运行时的 store 都同时写入了后端 DMEM，Cache 中没有脏行。但 PDU 写 DMEM 时绕过了 Cache，Cache 中可能还缓存着 PDU 修改前的旧数据。Flush 后所有 valid 位清零，CPU 后续访存会 miss 并重新从 DMEM 拉取最新数据。

---

## 9. CPU_ctrl 改造：调试请求等待

### 9.1 新增信号

```verilog
output [0:0] dmem_req,       // 新增：数据存储器请求保持信号
input  [0:0] dmem_ready,     // 新增：数据存储器事务完成
```

### 9.2 状态机扩展

原来 CPU_ctrl 的 `READ_DATA`/`WRITE_DATA` 状态假设 DMEM 零延迟，直接读写后 ACK。现在需要等待 DMEM 的 `ready` 信号：

```
READ_DATA ──> STATE_MEM_WAIT ──(dmem_ready)──> WAIT_ACK
WRITE_DATA ──> STATE_MEM_WAIT ──(dmem_ready)──> WAIT_ACK
```

在 `STATE_MEM_WAIT` 状态下，CPU_ctrl 持续保持 `dmem_req=1`，直到 DMEM 返回 `ready` 后才进入 `WAIT_ACK` 状态应答 PDU。

---

## 10. 分步接入流程

以下是将 Cache 接入一个已有的无 Cache 五级流水线 CPU 的推荐步骤：

### Step 1：改造 DMEM 为事务接口

1. 给 DMEM 添加 `req`/`ready` 握手协议。
2. 添加 `line_mode` 支持 128 位整行访问。
3. 添加 `MEM_DELAY` 参数模拟后端延迟。
4. **验证**：先用 `line_mode=0` 模式测试 32 位调试读写，确认 req/ready 握手正确。

### Step 2：改造 data_mem_ctrl

1. Store 路径：移除对 `rdata_in` 旧值的依赖，改为输出 `wdata_out` + `we_mask`。
2. Load 路径：保持不变。
3. **验证**：单独测试 SB/SH/SW 的掩码生成和 LB/LH/LW/LBU/LHU 的数据扩展。

### Step 3：实现 Cache 模块

1. 实现 `bram` 模块（组合读 + 同步写 + 复位清零）。
2. 实现 Cache 主体（状态机、Tag 查找、LRU 替换、miss refill、写直达）。
3. 用 testbench 单独测试 Cache 的 hit/miss/write-through 行为。
4. **验证**：
   - 连续 load 同一 Cache Line 内的不同字（应该命中）。
   - load 跨 Cache Line（应该 miss 后 refill）。
   - store 后再 load 同一地址（应该命中且返回 store 的值）。

### Step 4：改造 MEM_ARBITER

1. 数据侧从简单选择改为事务仲裁。
2. CPU 运行时选择 Cache Line 请求（128 位），CPU 停止时选择 CPU_ctrl 调试请求（32 位）。
3. 添加 `dmem_line_mode`、`dmem_line_wdata`/`dmem_line_rdata` 信号。
4. CPU 停止时 Cache 的 `ready` 强制置 0。

### Step 5：改造 CPU 的 MEM 阶段

1. 修改 CPU 端口：将 32 位直连 DMEM 接口替换为 128 位 Cache Line 事务端口。
2. 例化 Cache，连接 `data_mem_ctrl` 输出到 Cache 输入。
3. 实现 `dcache_req_active` 逻辑，防止 miss 等待期间重复发请求。
4. 实现 `dcache_wait` 信号，冻结整条流水线。
5. 修改 Hazard Detection Unit：Cache 等待优先级最高，stall 期间不允许 flush。
6. 冻结寄存器堆写回、commit 信号、DMEM 调试信息。
7. **验证**：运行简单的 load/store 程序，观察 Cache hit/miss 波形。

### Step 6：改造 CPU_ctrl

1. 添加 `dmem_req`/`dmem_ready` 端口。
2. 状态机增加 `STATE_MEM_WAIT`。
3. `READ_DATA`/`WRITE_DATA` 操作持续保持 `dmem_req`，直到 `ready` 返回。

### Step 7：改造 TOP

1. CPU 到 DMEM 的数据侧连线改为 128 位 Cache Line 通路。
2. CPU_ctrl 调试请求跨时钟域：上升沿检测 + pending 锁存。
3. DMEM ready 和读数据从 `cpu_clk` 同步回 `sys_clk`。
4. 实现 `cache_flush`：PDU 调试写 DMEM 完成后发一个 `cpu_clk` 周期的 flush。
5. **验证**：通过 PDU 单步执行、查看/修改数据存储器，确认调试功能正常。

### Step 8：集成测试

1. 运行完整 benchmark，对比有/无 Cache 的周期数。
2. 测试 PDU 调试写 DMEM 后继续运行，确认 Cache flush 生效。
3. 测试分支预测 + Cache 同时工作的场景。

---

## 11. 常见问题与注意事项

### 11.1 为什么 store hit 也要写直达？

PDU 在 CPU 停止后直接读取后端 DMEM 来检查 store 结果。如果采用写回策略，store 数据可能只存在于 Cache 中，PDU 看不到。写直达保证每次 store 都立即反映到后端 DMEM。

### 11.2 为什么不用写回策略？

写回策略需要处理脏行换出（write-back）、PDU 读时检查 Cache 是否有脏行等问题，复杂度显著增加。对于本项目的 PDU 调试需求和教学目的，写直达是最简单且安全的策略。

### 11.3 Cache miss 期间分支预测怎么办？

Cache miss 期间全流水线冻结，分支预测器的 `stall` 信号被拉高。预测器在 stall 期间不更新任何状态（BTB/RAS/BHT/PHT），也不响应新的预测请求。这保证了 Cache miss 恢复后预测器状态的一致性。

### 11.4 为什么 `dcache_req_active` 在 `!mem_access_MEM` 时清除？

当 MEM 阶段当前不是访存指令（如算术指令），`mem_access_MEM` 为 0，此时不应有任何 Cache 请求活跃。这个条件确保上一条访存指令完成后 `dcache_req_active` 能正确归零。

### 11.5 Cache flush 后的第一条访存会 miss 吗？

是的。Flush 清空了全部 valid 位，后续所有访存都会 miss 并从 DMEM 重新拉取。这是设计意图：PDU 修改 DMEM 后必须保证 CPU 不命中旧数据。性能代价是可接受的，因为 flush 只在 PDU 调试写时发生，不影响正常运行时的性能。

### 11.6 跨时钟域同步为什么要两级？

单级同步无法消除亚稳态。两级触发器将亚稳态传播概率从约 50% 降低到接近 0（对于合理的时钟频率和触发器 MTBF）。这是标准的 CDC（Clock Domain Crossing）做法。

### 11.7 MEM_ARBITER 的 `dmem_req` 在 CPU 停止时为什么要屏蔽 `dmem_ready`？

```verilog
assign cpu_ctrl_dmem_req = cpu_ctrl_dmem_req & ~dmem_ready;
```

因为 `dmem_ready` 是 `cpu_clk` 域的信号，在同步回 `sys_clk` 前可能维持多个 `cpu_clk` 周期。如果 CPU_ctrl 看到持续有效的 `req` 和 `ready`，可能在一个 `sys_clk` 周期内同时 ACK 当前事务和启动下一个事务。屏蔽 `ready` 当周期的 `req` 可以避免这种竞态。

### 11.8 非访存指令在 MEM 阶段会触发 Cache 吗？

不会。`mem_access_MEM = mem_read_MEM || mem_write_effective_MEM`。非访存指令时两者都为 0，`dcache_req_fire` 不会产生，`dcache_wait` 也为 0，流水线正常通过。

---

## 附录 A：信号速查表

| 信号名 | 方向 | 说明 |
|--------|------|------|
| `dcache_wait` | Cache → CPU | 流水线冻结信号 |
| `dcache_ready` | Cache → CPU | 本次访存完成 |
| `dcache_miss` | Cache → CPU | Cache 正在阻塞 |
| `dcache_req_active` | CPU 内部 | 防止重复发请求 |
| `dcache_req_fire` | CPU 内部 | 首次发起 Cache 请求 |
| `dcache_r_req` | CPU → Cache | load 请求脉冲 |
| `dcache_w_req` | CPU → Cache | store 请求脉冲 |
| `ctrl_wdata_MEM` | data_mem_ctrl → Cache | store 数据（已复制到字节通道） |
| `ctrl_we_mask_MEM` | data_mem_ctrl → Cache | 字节写掩码 |
| `dcache_rdata` | Cache → data_mem_ctrl | load 返回的 32 位字 |
| `cache_flush` | TOP → CPU | PDU 调试写后的 Cache flush |
| `dmem_mem_r` | Cache → 后端 | 整行读请求 |
| `dmem_mem_w` | Cache → 后端 | 整行写请求 |
| `dmem_mem_addr` | Cache → 后端 | Cache Line 基地址 |
| `dmem_mem_wdata` | Cache → 后端 | 写回的 128 位 Cache Line |
| `dmem_mem_rdata` | 后端 → Cache | 读回的 128 位 Cache Line |
| `dmem_mem_ready` | 后端 → Cache | 事务完成脉冲 |
| `dmem_req` | ARBITER → DMEM | 请求保持信号 |
| `dmem_ready` | DMEM → ARBITER | 事务完成脉冲 |
| `dmem_line_mode` | ARBITER → DMEM | 1=128位 Line，0=32位字 |

## 附录 B：Cache 参数配置参考

| 参数 | 当前值 | 含义 | 调整建议 |
|------|--------|------|----------|
| `INDEX_WIDTH` | 3 | 8 组 | 增大提高容量，增大面积 |
| `WAY_NUM` | 2 | 2 路组相联 | 增大降低冲突 miss，增大面积 |
| `LINE_OFFSET_WIDTH` | 2 | 每行 4 字 (128 位) | 增大提高空间局部性，增大 miss 惩罚 |
| `MEM_DELAY` | 4 | 后端延迟 4 周期 | 仅仿真用，不影响综合 |
