# JAL/JALR 分支预测重构方案

## 1. 当前架构分析

### 1.1 PDU 禁用信号链路

现有 PDU 已经通过 `CORE_BENCH_CTRL[0]` 暴露统一的分支预测禁用开关：

1. `PDU-Control/mmap.h` 将 `CORE_BENCH_CTRL` 定义在 `CORE_BASE + 0x58`，其中 bit0 为 `branch predictor disable`。
2. `PDU-Control/cmd.c` 的 `bpd` 命令只修改 bit0，保留 benchmark arm/clear/status 位。
3. `vsrc/PDU/CPU/CPU_ctrl.v` 在 `sys_clk` 域保存 `branch_predictor_disable`，PDU 写 `CORE_BENCH_CTRL` 时更新该寄存器。
4. `vsrc/TOP.v` 将 `branch_predictor_disable` 经两级同步送入 `cpu_clk` 域，并连接到 `CPU.branch_predictor_disable`。
5. `vsrc/PDU/CPU/your_cpu/cpu.v` 当前用该信号同时控制：
   - `branch_predictor.en = global_en && !branch_predictor_disable`
   - `bp_used_IF = !branch_predictor_disable && bp_pred_valid_IF`

当前 CPU 的关键安全点是：`bp_used_IF` 会随流水线进入 EX。若某条指令取指时没有真正使用预测器，EX 阶段就走无预测基线逻辑：真实 taken/JAL/JALR 统一重定向并 flush IF/ID、ID/EX。这保证了运行中切换禁用位时，每条指令按自身 IF 时刻的预测模式收尾。

### 1.2 现有控制流预测路径

现有 `branch_predictor.v` 是 tournament predictor：

- 条件分支：IF 阶段用局部/全局/选择器预测方向，目标地址由 `if_pc + if_imm` 得到。
- JAL：IF 阶段直接认为 taken，目标地址同样由 `if_pc + if_imm` 得到。
- JALR：IF 阶段不预测，EX 阶段必定 `redirect_valid`，真实目标为 `(rs1 + imm) & ~1`。

也就是说，当前代码虽然预留了 `META_IS_JALR`，但 JALR 没有提前目标；JAL 也没有 BTB 表项，不具备统一的控制流类型缓存。

## 2. 硬件结构设计

### 2.1 BTB 表项结构

新增 BTB 放在 `branch_predictor.v` 内，与 tournament predictor 共享同一组 `en/disable/stall` 控制。建议复用现有 `PC_IDX_W=8`，即 256 项直接映射 BTB，便于和现有 meta 的 PC index 宽度保持一致。

每个 BTB entry：

| 字段 | 建议位宽 | 说明 |
| --- | ---: | --- |
| `valid` | 1 | 表项是否有效 |
| `tag` | `32 - PC_IDX_W - 2` | `pc[31:PC_IDX_W+2]`，避免同 index 不同 PC 别名误命中 |
| `kind` | 2 | `00=BRANCH`，`01=JAL`，`10=JALR`，`11=reserved` |
| `target` | 32 | BRANCH/JAL 的实际目标；JALR 可记录最近一次真实目标作为调试或 RAS 空时的低置信 fallback |

IF 阶段查表：

```text
btb_idx = pc_IF[PC_IDX_W+1:2]
btb_hit = btb_valid[btb_idx] && btb_tag[btb_idx] == pc_IF[31:PC_IDX_W+2]
btb_kind = btb_kind_table[btb_idx]
```

EX 阶段训练/更新：

- 当 `ex_valid && !stall && predictor_active && (ex_is_branch || ex_is_jal || ex_is_jalr)` 成立时写 BTB。
- `kind` 来自 EX 真实 opcode，不信任 IF 的旧 BTB 类型。
- `target` 写入 `actual_target_EX`。
- 条件分支无论 taken 与否都可建立 BTB entry；方向仍由 PHT/BHT 决定，BTB 只提供类型和 taken 时的目标。

### 2.2 IF 阶段多路目标选择

BTB 命中后，IF 阶段按 `kind` 选择预测来源：

| BTB 类型 | 方向来源 | 目标来源 | `if_pred_valid` |
| --- | --- | --- | --- |
| BRANCH | tournament predictor | BTB `target` | BTB hit |
| JAL | 固定 taken | BTB `target` | BTB hit |
| JALR | 固定 taken | RAS 栈顶 | BTB hit 且 RAS 可用 |

推荐逻辑：

```text
if (!predictor_active || stall) {
    no prediction
} else if (btb_hit && kind == BRANCH) {
    pred_valid = 1
    pred_taken = local/global/choice result
    pred_target = btb_target
} else if (btb_hit && kind == JAL) {
    pred_valid = 1
    pred_taken = 1
    pred_target = btb_target
} else if (btb_hit && kind == JALR && ras_spec_not_empty) {
    pred_valid = 1
    pred_taken = 1
    pred_target = ras_spec_top
} else {
    no prediction
}
```

CPU 顶层 `next_pc` 仍保持当前优先级：

1. EX 阶段真实纠错/重定向最高优先级；
2. IF 阶段预测 taken 时使用预测目标；
3. 默认 `PC + 4`。

### 2.3 RAS 深度与工作原理

建议 RAS 深度为 8 或 16。考虑当前实验 CPU 资源规模，优先采用 8 项，后续若递归/深调用测试较多再扩大到 16。

RAS 状态建议分为两份：

1. `ras_arch_*`：解析态 RAS，只在 EX 阶段根据真实 JAL/JALR 更新，用于 flush 后恢复。
2. `ras_spec_*`：预测态 RAS，IF 阶段用于 JALR 预测，并可做投机 push/pop。

每份状态包含：

- `stack[0:RAS_DEPTH-1]`：返回地址数组。
- `sp`：下一次写入位置。
- `count`：当前有效深度，范围 `0..RAS_DEPTH`。

操作语义：

- Push：写入 `PC + 4`，`sp++`，`count++`。若 `count == RAS_DEPTH`，建议本次 push 直接丢弃，不覆盖旧项，从而简化回滚。
- Pop：当 `count != 0` 时，预测/返回目标为 `stack[sp - 1]`，然后 `sp--`，`count--`。
- 空栈：JALR 不使用 RAS 预测，回退到 EX 解析。若后续需要支持间接跳转，可在 RAS 空时使用 BTB `target` 作为低置信 fallback，但初始实现不建议启用，以免污染控制流。

按本次需求，初始策略采用：

- JAL：预测态 RAS 在 IF 预测命中时 push `PC + 4`；解析态 RAS 在该 JAL 到达 EX 时 push `PC + 4`。
- JALR：预测态 RAS 在 IF 预测命中且非空时 pop 栈顶作为预测目标；解析态 RAS 在该 JALR 到达 EX 时 pop。

更精细的 RISC-V 调用约定识别（如只在 `rd=x1/x5` 的 JAL push，只在 `rs1=x1/x5 && rd=x0` 的 JALR pop）可作为后续优化。本轮最小实现按需求描述处理：JAL push，JALR pop。

### 2.4 RAS 修复机制

为了避免 JALR 预测失败污染 RAS，EX 阶段需要在 redirect/flush 时修复 `ras_spec_*`：

1. EX 阶段先根据真实 opcode 计算 `ras_arch_next`。
2. 若当前 EX 控制流需要重定向，包括：
   - 条件分支方向预测错；
   - BTB 目标错；
   - BTB 类型错；
   - JAL/JALR 目标错；
   - BTB miss 后真实 taken/JAL/JALR 触发无预测重定向；
   则把 `ras_spec_*` 恢复为 `ras_arch_next`。
3. 若没有重定向，`ras_spec_*` 保留 IF 投机更新结果，`ras_arch_*` 追赶真实执行状态。

该方案避免为每条指令保存完整栈快照，只要 EX 是控制流解析点且所有错误路径都会 flush 年轻指令，`ras_arch_next` 就是重定向后正确路径应看到的 RAS 状态。

## 3. 流水线改造清单

### 3.1 `vsrc/PDU/CPU/your_cpu/branch_predictor.v`

主要改造集中在该文件：

1. 新增 BTB 数组：`valid/tag/kind/target`。
2. IF 阶段以 BTB 命中作为控制流预测入口。
3. tournament predictor 只负责条件分支方向，不再负责提供目标。
4. 新增 RAS 预测态/解析态状态机。
5. 扩展 meta 字段，至少保存：
   - IF BTB hit；
   - IF BTB kind；
   - IF predicted target；
   - IF predicted taken；
   - IF 是否执行过 RAS speculative push/pop；
   - IF RAS 预测目标是否有效。
6. EX 阶段比较预测与真实结果：
   - 方向不一致：redirect。
   - 预测 taken 但目标不一致：redirect。
   - 预测类型与真实 opcode 不一致：redirect，并用真实 opcode 更新 BTB。
   - JALR RAS 目标错误：redirect 到 `actual_target_EX`，并按 `ras_arch_next` 修复预测态 RAS。
7. 所有 BTB/BHT/PHT/Choice/RAS 写入都必须受 `predictor_active` 和 `!stall` 门控。

建议保留现有 `redirect_valid/redirect_pc` 接口，内部增强判断条件。若需要明确区分禁用信号来源，可将 `branch_predictor` 端口调整为：

```verilog
input wire en,       // global_en
input wire disable,  // branch_predictor_disable
```

内部统一生成：

```verilog
wire predictor_active = en && !disable;
```

这样 RAS 可以在 `global_en=1 && disable=1` 时丢弃投机态或保持冻结，而不会混淆 PDU 暂停 `global_en=0`。

### 3.2 `vsrc/PDU/CPU/your_cpu/cpu.v`

需要小幅调整 CPU 与预测器连接：

1. `branch_predictor` 实例传入统一禁用信号，或继续传入 `en = global_en && !branch_predictor_disable` 并在 CPU 外部保证 `bp_used_IF` 门控。
2. `bp_used_IF` 推荐改为：

```verilog
assign bp_used_IF = global_en && !branch_predictor_disable && bp_pred_valid_IF;
```

3. `next_pc` 优先级保持不变：

```verilog
assign next_pc = control_redirect_valid ? control_redirect_pc :
                 (bp_used_IF && bp_pred_taken_IF) ? bp_pred_target_IF :
                 pc_plus_4_IF;
```

4. EX 阶段 `actual_taken_EX` 和 `actual_target_EX` 现有逻辑可保留：

```verilog
actual_taken_EX = is_branch_EX ? cmp_res_EX : (is_jal_EX | is_jalr_EX)
actual_target_EX = is_jalr_EX ? {alu_out_EX[31:1], 1'b0} : alu_out_EX
```

5. 现有 flush 机制可继续使用 `control_redirect_valid`：
   - `if_id_flush = !dcache_wait && control_hazard`
   - `id_ex_flush = !dcache_wait && (load_use_hazard || control_hazard)`

### 3.3 `vsrc/PDU/CPU/your_cpu/pipe_reg.v`

若 meta 仍保持 32 位，需要重新分配字段；如果字段不足，建议把 `META_W` 扩到 48 或 64，并只修改 `cpu.v` 中三处 `bp_meta` wire/pipe_reg 宽度。

推荐扩到 64 位，降低后续维护风险。示例字段：

| 位段 | 含义 |
| --- | --- |
| `[7:0]` | PC index |
| `[13:8]` | local history snapshot |
| `[21:14]` | GHR snapshot |
| `[22]` | local pred |
| `[23]` | global pred |
| `[24]` | choice use global |
| `[25]` | pred taken |
| `[26]` | pred valid |
| `[28:27]` | predicted kind |
| `[29]` | BTB hit |
| `[30]` | RAS op valid |
| `[31]` | RAS op is pop |
| `[63:32]` | predicted target |

若采用 `ras_arch/spec` 双状态修复，则无需在 meta 内保存完整 RAS sp/count 快照。

### 3.4 `vsrc/TOP.v` 与 `vsrc/PDU/CPU/CPU_ctrl.v`

原则上不需要新增 PDU 寄存器或顶层端口。现有 `branch_predictor_disable` 已经满足统一禁用开关要求。

只有在 `branch_predictor` 接口从单一 `en` 改为 `en + disable` 时，`TOP.v` 不需要变，`cpu.v` 实例连接处需要把 `branch_predictor_disable` 原样传入预测器。

## 4. PDU 旁路接入方案

统一原则：BTB、BHT/PHT/Choice、RAS 必须共享同一个 `branch_predictor_disable`，不能新增第二套 debug 开关。

### 4.1 预测输出门控

当 `branch_predictor_disable=1`：

- `if_pred_valid=0`。
- `if_pred_taken=0`。
- CPU `next_pc` 只能在 EX 真实重定向或默认 `PC+4` 中选择。
- JAL/JALR 不允许在 IF 阶段使用 BTB/RAS 改写 `next_pc`。

### 4.2 状态写入门控

当 `branch_predictor_disable=1`：

- BTB 不写入、不替换。
- 条件分支 BHT/PHT/Choice 不训练。
- RAS 不 push、不 pop。
- 若实现了预测态 RAS，建议在禁用有效且 CPU 正在运行时将 `ras_spec_*` 恢复到 `ras_arch_*`，以丢弃禁用前残留的错误路径投机状态；该动作不是 push/pop，不改变解析态历史。

### 4.3 与现有 `bp_used` 机制的关系

继续保留 `bp_used_IF -> bp_used_ID -> bp_used_EX`。

- 取指时禁用：`bp_used_IF=0`，该指令到 EX 后必然走无预测基线。
- 取指时启用、后来禁用：该指令仍携带 `bp_used_EX=1`，EX 阶段可以用 meta 完成正确 redirect；但预测器状态写入应受当前 `branch_predictor_disable` 抑制，避免 PDU 禁用期间继续训练。

这与现有实现的思想一致：控制流正确性由流水线 meta 保证，微结构学习状态由 PDU 开关统一门控。

## 5. 潜在冲突与解决预案

### 5.1 BTB 别名导致类型错误

风险：直接映射 BTB 不同 PC 映射到同一 index，若 tag 比较缺失，会把普通指令或另一类控制流误认为 JAL/JALR。

预案：BTB 必须包含 tag。EX 阶段若发现预测 kind 与真实 opcode 不一致，立即 redirect 到真实目标或 `PC+4`，并用真实 opcode 覆盖 BTB entry。

### 5.2 RAS 投机状态污染

风险：JAL push 或 JALR pop 在 IF 投机执行，随后前方分支预测失败，年轻路径的 RAS 修改必须撤销。

预案：使用 `ras_arch_*` 和 `ras_spec_*` 双状态。EX 发生任何 control redirect 时，以 `ras_arch_next` 覆盖 `ras_spec_*`。这样 flush 年轻指令的同时也 flush 其 RAS 投机副作用。

### 5.3 JALR 目标错误

风险：RAS 栈顶不等于真实 `(rs1 + imm) & ~1`，尤其是间接跳转或栈溢出/空栈场景。

预案：

- JALR 预测只在 `RAS count != 0` 时有效。
- EX 比较 `pred_target` 与 `actual_target_EX`，不一致时 redirect 到真实目标。
- 发生错误时用真实 JALR 对 `ras_arch_next` 做一次 pop，再恢复 `ras_spec_*`，保证栈指针与正确路径一致。

### 5.4 Cache stall 与预测状态重复更新

风险：`dcache_wait` 期间流水线寄存器保持，如果 BTB/RAS 在 stall 周期重复训练或重复 push/pop，会破坏状态。

预案：所有 IF 投机 RAS 更新和 EX 训练更新都必须加 `!stall`，与现有 `train_fire = en && !stall && ...` 保持一致。CPU 当前传入 `stall(dcache_wait)`，可继续复用。

### 5.5 禁用开关运行中切换

风险：PDU 在 CPU 连续运行期间拉高 `branch_predictor_disable`，IF 端不能继续预测，RAS/BTB 不能继续变化。

预案：

- `TOP.v` 已经把禁用信号同步到 `cpu_clk` 域。
- `branch_predictor` 内部用 `predictor_active = global_en && !branch_predictor_disable` 统一门控输出和写入。
- 取指时禁用的控制流指令不携带 `bp_used`，EX 自动回退到真实解析路径。

### 5.6 RAS 溢出与下溢

风险：深调用超过 RAS 深度，或 JALR 在空栈时预测。

预案：

- 下溢：`count == 0` 时 JALR 不预测，EX 真实跳转。
- 溢出：初始实现采用饱和策略，满栈时丢弃新 push，不覆盖旧项，优先保证回滚简单和状态可解释。

## 6. 建议实施顺序

1. 在 `branch_predictor.v` 中加入 BTB 表和 kind 编码，先让 BRANCH/JAL 走 BTB 目标。
2. 扩展 meta 到 64 位，把 predicted target/kind 随流水线带到 EX。
3. 加入 JALR 的 RAS 预测路径，但先仅在 RAS 非空时预测。
4. 加入 EX 阶段 BTB 更新、目标校验和 redirect 条件增强。
5. 加入 `ras_arch/spec` 双状态修复。
6. 最后统一审查所有 `branch_predictor_disable`、`global_en`、`dcache_wait` 门控，确认禁用时 BTB/RAS/BHT/PHT/Choice 全部停止工作。

