# Benchmark 执行总结

## 1. 本次完成的工作

本次已经按 `AI_assistance/Benchmark_Integration_Plan.md` 完成基准测试能力集成，核心目标有三项：

1. 在 PDU / CPU_ctrl 中加入可读写的 benchmark 控制寄存器与周期结果寄存器。
2. 在 CPU 内部加入精确到 `cpu_clk` 周期的计时器，统计从“第一条指令真正进入执行”到“最后一条指令退休”的完整跨度。
3. 为 CPU 增加 `branch_predictor_disable` 硬连线旁路，使分支预测器可以在运行时动态关闭，并且不会污染既有历史表状态。

## 2. 关键实现说明

### 2.1 计时器边界

计时器放在 `vsrc/PDU/CPU/your_cpu/cpu.v` 的 CPU 时钟域内，计数单位为 `cpu_clk` 周期，而不是 `sys_clk` 周期。

- Start 条件：`benchmark_arm && !benchmark_running_reg && !benchmark_done_reg && global_en && !pc_stall`
- Stop 条件：`benchmark_running_reg && commit_advance && commit_WB && halt_WB`

这样定义的结果是：

- 第一条指令真正被 IF 接收的那一拍计为第 1 个周期。
- 最后一条 `EBREAK` 在 WB 阶段退休的那一拍也会被计入总周期。
- Cache stall、load-use stall、分支 flush 等真实执行开销都会被统计进去。

### 2.2 分支预测旁路

新增 `branch_predictor_disable` 后，CPU 取指与 EX 纠错遵循“按指令生成时的模式收尾”的策略：

- IF 阶段：禁用时直接走 `PC + 4`
- EX 阶段：如果这条指令取入时确实使用过预测器，则沿用预测器纠错路径；如果没有使用过，则退回无预测分支解析

为了避免关闭预测器后写回脏状态，`branch_predictor.v` 只允许对“确实使用过预测器的分支”进行训练回写。

### 2.3 PDU 串口命令

已新增三条命令：

- `bpd [0|1]`
  - 无参数：查询分支预测器当前状态
  - `1`：关闭分支预测器
  - `0`：开启分支预测器
- `brun`
  - 直接触发硬件 `RUN`
  - 由 CPU 内部计时器统计整段 benchmark 周期
- `cycles`
  - 打印最近一次 benchmark 的周期结果

## 3. 控制寄存器定义

新增的 PDU 控制寄存器位于：

- `CORE_BENCH_CTRL`  = `CORE_BASE + 0x58`
- `CORE_BENCH_CYCLES` = `CORE_BASE + 0x5C`

`CORE_BENCH_CTRL` 位定义：

| 位号 | 含义 |
| --- | --- |
| `[0]` | `branch_predictor_disable` |
| `[1]` | `benchmark_arm` |
| `[2]` | `benchmark_clear` |
| `[8]` | `benchmark_done` |
| `[9]` | `benchmark_running` |

## 4. 修改清单

### `vsrc/PDU/CPU/your_cpu/cpu.v`

- 新增 `branch_predictor_disable / benchmark_arm / benchmark_clear` 输入端口。
- 新增 `benchmark_clear_ack / benchmark_done / benchmark_running / benchmark_cycles` 输出端口。
- 增加 `bp_used_IF / bp_used_ID / bp_used_EX` 旁路侧带位。
- 取指阶段在禁用预测时强制使用 `PC + 4`。
- EX 阶段加入“预测模式 / 无预测模式”双路径控制流收尾逻辑。
- 增加 CPU 域 benchmark timer，并在同一拍锁存停表结果。

### `vsrc/PDU/CPU/your_cpu/branch_predictor.v`

- 增加 `ex_bp_used` 输入。
- 训练逻辑增加使能门控，防止禁用预测时的分支误写入历史表。

### `vsrc/PDU/CPU/CPU_ctrl.v`

- 新增 `CORE_BENCH_CTRL`、`CORE_BENCH_CYCLES` 映射。
- 新增 benchmark 控制寄存器镜像与周期快照寄存器。
- 将 benchmark 控制位通过寄存器窗口暴露给 PDU 串口固件。

### `vsrc/TOP.v`

- 新增 CPU / sys_clk 域之间的同步信号。
- 将 benchmark 与分支预测旁路控制信号接入 CPU 和 CPU_ctrl。
- 增加 benchmark 结果回传的跨时钟域同步链路。

### `PDU-Control/mmap.h`

- 新增 `CORE_BENCH_CTRL` 和 `CORE_BENCH_CYCLES` 地址定义。

### `PDU-Control/cmd.h`

- 新增 benchmark 与分支预测器控制命令枚举。

### `PDU-Control/cmd.c`

- 新增 `brun`、`cycles`、`bpd` 命令解析与执行。
- `brun` 采用硬件 RUN，不再走 step 循环，避免串口开销污染 benchmark 结果。
- `bpd` 支持查询和动态切换分支预测器。

### `PDU-Control/README.md`

- 更新命令帮助，补充 benchmark 相关操作说明。

## 5. 验证结果

已完成 RTL 顶层语法检查：

```powershell
iverilog -g2012 -I vsrc\include -o build\benchmark_check.vvp ...
```

结果：通过。

本机未找到以下工具，因此未在当前环境重建 PDU-Control 交叉编译固件：

- `make`
- `riscv64-unknown-linux-gnu-gcc`
- `riscv64-unknown-elf-gcc`

## 6. 使用方法

建议的 benchmark 操作顺序：

1. `reset`
2. `bpd 1` 或 `bpd 0`
3. `brun`
4. 查看自动打印的 cycle 结果，或再执行一次 `cycles`

如果只想查询当前是否关闭预测器：

```text
bpd
```

## 7. 说明

- 现有 `step` / `run` / `reset` 逻辑保持不变。
- benchmark 功能通过新增命令和寄存器窗口独立接入，不影响原有调试流程。
- 由于控制信号采用跨时钟域同步，旁路开关与计时结果读取不会直接进入 CPU 数据通路关键路径。
