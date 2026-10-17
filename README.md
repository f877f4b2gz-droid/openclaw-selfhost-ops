# openclaw-selfhost-ops (v2.0)
> 自托管 AI Agent 资产与知识治理框架。告别上下文膨胀、知识漂移。

本项目基于多智能体协同生产环境打磨提炼，去除了内部执行细节，提取了通用架构与规范。

> 本项目 v2.0 基于双机协作环境提炼，v1.0 的基础运维脚本（log-rotate 等）与 v2.0 的治理框架互补并存。

## v2.0 核心组件
- [x] 索引与指针防漂移（Total Index & Pointer Check）
- [x] 垃圾回收与存活期考核（Scratch Sweep）
- [x] 复用资产静态分析（Ref Count）
- [x] 反馈闭环与队列（Exp Scan & Queue）

## 依赖说明
本框架深度集成 OpenClaw 自托管环境，部分高阶功能依赖私有库（如 `/usr/local/lib/wk.sh`、`qq-send.sh`）。开源版本提供基础逻辑，外部环境需自行适配对应接口。脚本在缺失私有库时会打印警告并降级运行（日志/通知回退到终端输出），不会中断主流程。
