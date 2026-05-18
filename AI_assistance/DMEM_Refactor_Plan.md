# DMEM 架构级重构方案

## 第一阶段：DMEM 架构与接口分析

### 1. CPU / Cache / DMEM 接口需求

当前数据访存链路为：

`CPU MEM 阶段 -> DCache -> MEM_ARBITER -> DMEM`

DCache 对后端 DMEM 的接口为整条 Cache Line 事务：

- `mem_r`：整行读请求。
- `mem_w`：整行写请求。
- `mem_addr[31:0]`：字节地址，DCache 已将其对齐到 16 字节 Cache Line 边界。
- `mem_w_data[127:0]`：写直达主存的 128 位 Cache Line，低地址字节位于低位。
- `mem_r_data[127:0]`：DMEM 返回的 128 位 Cache Line。
- `mem_ready`：DMEM 事务完成脉冲，Cache 在该周期采样返回数据或确认写完成。

CPU 暂停时，`CPU_ctrl` 通过 `MEM_ARBITER` 访问同一后端 DMEM：

- 访问粒度为 32 位字。
- `cpu_ctrl_dmem_req` 会保持到 `cpu_ctrl_dmem_ready` 返回。
- 顶层 `TOP.v` 已将调试请求同步到 `cpu_clk` 域，并将 `ready/rdata` 同步回 `sys_clk` 域。

`MEM_ARBITER` 对 DMEM 的统一接口为：

- `req`：事务请求，保持到 `ready`。
- `we`：1 表示写，0 表示读。
- `line_mode`：1 表示 128 位 Cache Line 访问，0 表示 32 位调试字访问。
- `addr[DEPTH-1:0]`：以 32 位 word 为单位的 DMEM 内部地址。`TOP.v` 已先执行 `dmem_addr - DMEM_START_ADDR`，再取 `[DEPTH+1:2]`。
- `wdata/rdata`：32 位调试字数据。
- `line_wdata/line_rdata`：128 位 Cache Line 数据。
- `ready`：事务完成脉冲，高电平持续一个 `cpu_clk` 周期。

当前 `DEPTH=10`，即 DMEM 一共有 `2^10` 个 32 位字，总容量 4 KiB；DCache Line 为 4 个 32 位字，即 16 字节。

### 2. 当前 DMEM 内部架构问题

现有 `DMEM.v` 使用：

```verilog
reg [31:0] mem [0:(1 << DEPTH)-1];
```

并在一个完成周期内对同一数组执行最多 4 个不同 word 地址的读或写，用于拼接/更新 128 位 Cache Line。

这种写法虽然仿真正确，但对 FPGA 综合不友好：

- 一个事务完成周期里出现 4 个独立 word 读口或写口风格。
- 调试 32 位访问和 Cache 128 位访问共用同一个 32 位数组。
- Vivado 很容易放弃 Block RAM 推断，将数组展开为寄存器/LUT 逻辑。
- 之前综合报告已经显示 `dmem` 是 LUT 超额的主要来源。

### 3. 重构后的存储器组织方式

综合验证中，128 位宽 line array 虽然已经把 DMEM 从寄存器/LUT 爆炸中解放出来，但 Vivado 仍倾向于把 `256 x 128` 的小深度宽 RAM 映射为 LUTRAM。为了更稳定地使用 FPGA Block RAM，本次最终采用 32 位 word 阵列 + 事务微序列器：

```verilog
(* ram_style = "block" *) reg [31:0] mem [0:(1 << DEPTH)-1];
```

其中：

- `LINE_WORDS = 4`
- `addr` 仍为 32 位 word 地址。
- `line_mode=1` 时，DMEM 将地址低 2 位清零，作为 4-word Cache Line 的基地址。
- 整行读写由 FSM 连续访问 4 个 32 位 word，每拍只访问一个 BRAM 地址。
- `line_rdata[31:0]` 对应最低地址 word，`line_rdata[127:96]` 对应最高地址 word。

这样仍保持原有 32 位初始化文件和外部接口不变，同时避免旧版 DMEM 在一个周期内对同一数组访问 4 个不同地址的多端口 RAM 形态。

### 4. BRAM 推断策略

重构后的 DMEM 遵循更典型的单端口同步 RAM 模式：

- 只在时钟上升沿访问存储阵列。
- 每个时钟周期最多访问一个 `mem[address]`。
- 32 位调试读写只访问一个 word 地址。
- 128 位 Cache Line 读写拆成 4 个连续 word 访问。
- 写路径使用 `line_mode + word_step` 形成内部 word 选通信号；DCache 已在上层按字节掩码完成 SB/SH/SW 的局部合并，写直达到 DMEM 的是完整 Cache Line。
- 不复位整个 RAM 内容，只复位控制寄存器和输出寄存器。

该写法比原来的 32 位数组多地址并行访问更容易被 Vivado 映射到 BRAM，避免 DMEM 被展开成大规模 LUT/FF。

## 第二阶段：重构后接口定义与时序说明

### 1. DMEM 外部端口

本次重构保持 `DMEM` 模块外部端口不变，以降低对 `TOP.v`、`MEM_ARBITER.v` 和 DCache 的连线扰动：

| 端口 | 方向 | 含义 |
| --- | --- | --- |
| `clk` | input | DMEM 工作时钟，当前接 `cpu_clk` |
| `req` | input | 请求保持信号，事务开始后保持到 `ready` |
| `we` | input | 1 写 / 0 读 |
| `line_mode` | input | 1 为 128-bit Cache Line 事务，0 为 32-bit word 调试事务 |
| `addr[DEPTH-1:0]` | input | 32 位 word 地址 |
| `rdata[31:0]` | output reg | 32 位 word 读返回 |
| `wdata[31:0]` | input | 32 位 word 写数据 |
| `line_rdata[127:0]` | output reg | 128 位 Cache Line 读返回 |
| `line_wdata[127:0]` | input | 128 位 Cache Line 写数据 |
| `ready` | output reg | 事务完成脉冲 |

### 2. 握手时序

DMEM 使用两态事务 FSM：

1. `IDLE`
   - 当 `req=1` 时锁存 `addr/we/line_mode/wdata/line_wdata`。
   - 计算并锁存 `line_index`、`word_offset`、内部写掩码和对齐后的 128 位写数据。
   - `delay_cnt <= MEM_DELAY`，进入 `BUSY`。

2. `DELAY`
   - `delay_cnt != 0` 时每周期递减，用于模拟后端主存延迟。
   - `delay_cnt == 0` 后启动实际 RAM 访问。
   - 32 位写在该阶段完成并拉高 `ready`。
   - 128 位写在该阶段连续写 4 个 word，最后一个 word 写完时拉高 `ready`。
   - 读事务转入 `READ_WORD`。

3. `READ_WORD`
   - 32 位读采样一个 word 后转入 `DONE`。
   - 128 位读连续采样 4 个 word，按低地址到高地址拼入 `line_read_buf` 后转入 `DONE`。

4. `DONE`
   - 拉高 `ready` 一个周期。
   - 读事务在该周期给出有效 `rdata/line_rdata`。

请求方必须保持 `req` 到 `ready`。DMEM 在 `BUSY` 状态不会重新采样输入，避免同一事务被重复启动。

### 3. 读写掩码与选通策略

DMEM 内部使用 word 级微序列选通：

- 32 位调试写：只选通 `addr_buf` 指向的 1 个 word。
- 128 位 Cache Line 写：通过 `word_step=0..3` 依次选通 4 个连续 word。
- 32 位调试读：只读取 `addr_buf` 指向的 1 个 word。
- 128 位 Cache Line 读：通过 `word_step=0..3` 依次读取 4 个连续 word。

DCache 侧的 SB/SH/SW 字节级合并已经在 Cache Line 内完成：

- `data_mem_ctrl.v` 生成 CPU store 的字节写掩码。
- `n_way_cache.v` 在命中行或 refill 行内按字节掩码执行读-改-写合并。
- DMEM 接收的是写直达后的完整 128 位 Cache Line，因此后端 BRAM 只需要保证 line 内 4 个 word 的顺序和选通正确。
- 这种分层避免了 DMEM 为字节写另建多端口/宽掩码 RAM，也不会丢失 CPU 的字节/半字访问语义。

### 4. 初始化策略

现有 `CPU_DMEM_FILE` 是 32 位 word 粒度的 hex 文件。最终实现继续使用 32 位 word 阵列，因此初始化保持简单直接：

```verilog
$readmemh(`CPU_DMEM_FILE, mem);
```

这保证仿真环境仍能完整加载数据内存阵列，不会出现空壳 DMEM 或未初始化后端存储。

## 第三阶段：关联模块修改评估

本次预计只需要重写：

- `vsrc/PDU/CPU/memory/DMEM.v`

原因：

- DMEM 外部端口保持不变。
- `TOP.v` 中的地址裁剪仍然输出 word 地址，与新 DMEM 的 `addr` 定义一致。
- `MEM_ARBITER.v` 已能区分 `line_mode`，无需额外信号。
- DCache 已经在 Cache Line 内使用 CPU 侧 `w_mask` 完成字节合并，写直达到 DMEM 的是完整 128 位 line。

实施后需要重点验证：

- 32 位调试读写不会破坏同一 128 位 line 内其他 word。
- 128 位 Cache Line 读写的 word 排列仍保持低地址 word 在低 32 位。
- `ready` 仍是单周期脉冲，且读数据在该周期有效。
- Verilog 语法检查通过。

## 第四阶段：验证计划

完成代码修改后执行：

1. 运行 Verilog 编译/语法检查，确认端口、位宽和数组访问合法。
2. 若 Vivado 可用，重新执行综合或已有综合脚本，观察 DMEM 是否不再占用超大规模 LUT/FF。
3. 创建执行总结文档 `AI_assistance/DMEM_Execution_Summary.md`，记录实际修改文件、diff 简述和验证结果。
