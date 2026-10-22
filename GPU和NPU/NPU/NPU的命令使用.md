### 1.昇腾的运维工具不像 NVIDIA 生态那样“一个 nvidia-smi 包打天下”，而是做了明确的功能分层：

npu-smi：轻量巡检，对标 nvidia-smi，负责看资源水位和进程归属。

ascend-dmi：硬件诊断与性能基准，对标 deviceQuery + bandwidthTest，在 npu-smi 发现异常后进一步定位根因。

msprof：算子级性能 Profiling，对标 Nsight / torch.profiler，负责回答“时间花在哪”。

`排查时的工具链条是：npu-smi 发现问题 → ascend-dmi 诊断根因 → msprof 定位性能瓶颈。`


# 一、npu-smi

