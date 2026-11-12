# NVIDIA / RTX 4060 GPU 排查命令与面试要点

> 说明：GPU 侧的命令本身不难，**难的是在 4060 这类消费级卡上，哪些工具能用、哪些指标需要换一种读法**。

---

## 一、第一梯队：日常必用，覆盖 80% 场景

### `nvidia-smi` —— 所有排查的起点

概览表里优先盯三样：**Memory-Usage、Volatile GPU-Util、Processes 表**。

在 4060 上，`GPU-Util` 的语义是"采样周期内有 kernel 在执行的时间占比"，**低 Util 不等于卡在偷懒**，短 kernel 之间的空隙会被采样掩盖。

### `nvidia-smi pmon -s um` —— 定位"显存被谁占了"的首选

- `pmon` 按进程输出，`-s um` 同时显示利用率和 Frame Buffer 占用。
- 如果 `nvidia-smi` 的 Process 表里**没有对应 PID 但显存仍然被占着**，说明发生了"幽灵占用"——进程退出后驱动上下文残留。
- 4060 上可尝试 `nvidia-smi -r` 做软复位（需 root，只影响指定 GPU）。

### `dmesg | grep -i 'xid\|nvrm'` —— 驱动/硬件层的第一现场

- 任务莫名中断、卡从列表消失、出现诡异的通信类报错时，先翻这里。
- `Xid` 是 NVIDIA 驱动记录的错误事件代码，**不是"故障部件编号"**，同样的 Xid 在不同型号、不同上下文下处理方式可能不同。

### `nvidia-smi --query-gpu=index,utilization.gpu,memory.used,temperature.gpu,power.draw --format=csv` —— 结构化取数入口

- 适合脚本化轮询或做基线快照。
- 字段列表随驱动版本变化，**`nvidia-smi --help-query-gpu` 是当前机器支持字段的权威依据**，比凭记忆硬写可靠。

---

## 二、第二梯队：按场景选用，性价比很高

| 命令 | 用途 |
|---|---|
| `nvidia-smi dmon -s pucvmet -d 1` | **设备级趋势监控**。`dmon` 逐设备一行，适合看"卡忙不忙"的滚动曲线；与 `pmon`（逐进程一行，定位"谁在忙"）分工要分清 |
| `nvidia-smi -q -d MEMORY,PROCESSES` | **显存泄漏定位的经典组合**。结合进程树信息，快速判断是哪个进程的显存占用持续爬升而没有回落 |
| `nvidia-smi --query-gpu=timestamp,name,utilization.gpu,memory.used --format=csv -l 1 -f gpu_log.txt` | **带时间戳的落盘监控**。比 `watch` 更适合事后复盘，尤其"显存突然涨了但利用率没涨"时，时间戳能把两个指标对齐来看 |
| `nvidia-smi nvlink -e`（如卡支持 NVLink） | **多卡通信异常时先看链路错误计数**。4060 不支持 NVLink，留到接触多卡 NVLink 环境再用 |
| `nvidia-bug-report.sh` | **一键生成完整诊断报告**。问题已超出"看一眼指标"范畴时，该脚本收集的现场信息远比手动拼命令齐全，适合提交硬件支持或深度复盘 |

---

## 三、关于 DCGM 和 4060 的现实

- **DCGM 的完整能力在 RTX 4060 这类消费级 GeForce 卡上会被大幅阉割**，大量高级监控接口不开放。
- `dcgmi diag` 的深度诊断级别在 4060 上部分检查项可能不可用，**不要把它当成 4060 上的主力排查工具**。
- DCGM 的真正定位是**生产级集群监控**——`dcgm-exporter` + Prometheus + Grafana，提供 `nvidia-smi` 给不了的真实 SM 活跃度、Tensor Core 利用率、DRAM 带宽等指标。
- 在单卡 4060 开发机上，**`nvidia-smi` 完全够用**，把精力花在读懂 `nvidia-smi` 的字段语义上，收益比折腾 DCGM 大得多。

---

## 四、Xid 速查：面试和实战都绕不开

| Xid | 含义 | 一线动作 |
|---|---|---|
| **13** | 图形引擎异常 | 驱动 bug 或应用越界；重启进程，反复出现则考虑降级驱动 |
| **31** | MMU fault，地址越界 | **通常是用户代码 CUDA 越界**，不是硬件故障 |
| **43** | GPU 停止处理 | 进程崩溃或 OOM；重启容器 |
| **63** | ECC 页退休 | HBM 可纠正错误，页被屏蔽；**记录并观察**，运行计数 > 5 考虑排空节点 |
| **64** | ECC 页退休失败 | 退休失败 → **排空节点** |
| **74** | NVLink 错误 | 查 `nvidia-smi nvlink -e`；多卡同时出现 → 重启节点 |
| **79** | GPU 从总线上掉卡 | 硬件故障；重启无效则 **RMA** |
| **119/120** | 保密计算 / 不可恢复 HBM | 不可恢复；**排空、RMA** |

**实战策略**：**13/31/43 先自动重试一次；63 计数持续增长 → 排空并标记；64/79/119/120 → 隔离节点并升级到硬件处理**。

---

## 五、面试高频问题与回答框架

### ❓ `GPU-Util` 很高，但任务还是慢，可能是什么原因？

**高 Util 不等于高算力效率**。`utilization.gpu` 只表示采样窗口内有 kernel 在执行，**不反映 SM 或 Tensor Core 的真实活跃度**。

一个常见的"假繁忙"场景：GPU Util 90%，但 Tensor Core 利用率只有 25%——说明算子跑在 fp32 上，而不是该用的 fp16。在 4060 上如果只凭 `nvidia-smi` 判断，可以结合**功耗是否接近上限、`pstate` 是否在 P0** 来辅助判断；更精确的 SM 活跃度需要 DCGM，但消费级卡支持有限。

**面试时能把"Util 高 ≠ 算力用满了"讲清楚，比背命令更有区分度。**

### ❓ 训练进程突然挂了，怎么排查？

**顺序是：先看 `dmesg` 里的 `Xid`，再看 `nvidia-smi` 的资源水位，最后才怀疑代码。**

- `Xid 31` 和 `Xid 13` 很多时候是**用户代码越界**，不是硬件坏了；
- `Xid 79` 才是需要认真考虑 RMA 的信号；
- 如果 `dmesg` 里没有 Xid，再用 `nvidia-smi -q -d MEMORY,PROCESSES` 确认是不是显存问题或进程残留。

**把 Xid 按"可自愈 / 需干预 / 硬件嫌疑"分级，是面试里很实用的表达框架。**

### ❓ 显存被占了但找不到进程，怎么办？

这是经典的**幽灵占用**。`nvidia-smi` 的 Process 表里没有 PID，但 Memory-Usage 仍然很高，说明进程退出后驱动上下文没释放。

- 在 4060 上可尝试 `nvidia-smi -r` 做软复位（root，只作用于指定 GPU）。
- 复位无效再考虑重启节点。
- **和 NPU 侧"不轻易重启整机"的原则一致：先走设备级清理，再升级到系统级动作。**

### ❓ `nvidia-smi` 和 DCGM 应该怎么选？

- **单卡开发机、快速看一眼、SSH 上去巡检**——`nvidia-smi` 足够。
- **生产集群、需要历史趋势、需要 Prometheus 告警、需要真实 SM/Tensor Core 活跃度**——DCGM。

面试被追问"为什么生产不能只靠 `nvidia-smi`"时，关键点是：**`nvidia-smi` 是单机快照，采样粒度粗，没有原生指标导出和健康策略体系**。能把这个边界说清楚，比单纯罗列 DCGM 功能更能体现判断力。

---

## 六、一句话排查链路（GPU 版）

> **先 `dmesg` 看 Xid → 再 `nvidia-smi` 看资源水位 → 再 `pmon` 定进程归属 → 显存残留走 `nvidia-smi -r` → 性能问题才上 Profiling（`torch.profiler` / Nsight）**。

和 NPU 侧相比，GPU 排查多了一个**非常前置的 Xid 信号**：Xid 出现得早、语义相对成熟，很多问题在看资源指标之前就已经被 `dmesg` 定性了。**先读 Xid，再读水位**，是 GPU 侧值得养成的顺序习惯。
