# openclaw-selfhost-ops (v2.0)
> 自托管 AI Agent 资产与知识治理框架。告别上下文膨胀、知识漂移。

> 本项目 v2.0 基于双机协作环境提炼，v1.0 的基础运维脚本（log-rotate 等）与 v2.0 的治理框架互补并存。

## v2.0 核心组件
- [x] 索引与指针防漂移（Total Index & Pointer Check）
- [x] 垃圾回收与存活期考核（Scratch Sweep）
- [x] 复用资产静态分析（Ref Count）
- [x] 反馈闭环与队列（Exp Scan & Queue）
