# openclaw-selfhost-ops (v2.0)
> 自托管 AI Agent 资产与知识治理框架。告别上下文膨胀、知识漂移。

本项目基于多智能体协同生产环境打磨提炼，去除了内部执行细节，提取了通用架构与规范。

## Overview（背景）

长期运行的自托管 AI 助手会产生三类工程问题：**知识漂移**（同一事实多处副本、互相矛盾）、**资产腐烂**（临时脚本与日志无界增长）、**经验流失**（踩坑结论不回流、重复犯错）。本框架以"唯一真相源 + 字典式索引 + 定期自动巡检"为核心思路，提供一组可独立运行的治理脚本与规范文档。v2.0 在此之上新增知识治理闭环（治理类脚本），与 v1.0 的基础运维脚本（备份、日志轮转、清理类）互补并存。

## Architecture（架构）

```text
openclaw-selfhost-ops/
├── scripts/              治理与运维脚本（bash）
│   ├── scratch-sweep.sh  草稿区存活期考核与回收
│   ├── ref-count.sh      脚本被引次数静态分析（分层考核）
│   └── exp-scan.sh       经验库扫描与反馈队列
├── lib/
│   └── ops_lib.sh        公共库：配置加载、依赖降级、路径校验
├── templates/
│   └── ops.conf.example  配置模板（安装为 /etc/openclaw-ops/ops.conf）
├── docs/                 规范与设计文档
└── cron/                 示例定时表
```

核心机制（四大模块）：
- [x] **索引与指针防漂移**（Total Index & Pointer Check）：资产只立一处字头，跨类经检字表检索；文档间只传指针、不复制正文（详见 `docs/信息资产管理规范.md`）
- [x] **垃圾回收与存活期考核**（Scratch Sweep）：`scripts/scratch-sweep.sh` 对草稿区按"存活 ≥30 天 ∧ 被引 =0 ∧ 连续两轮 =0"移入回收站；存量豁免、首轮只出清单
- [x] **复用资产静态分析**（Ref Count）：`scripts/ref-count.sh` 统计散落脚本被引次数，按层级（共享/被引/依赖/未沉淀/豁免）输出考核依据
- [x] **反馈闭环与队列**（Exp Scan & Queue）：`scripts/exp-scan.sh` 离线聚类重复踩坑与可复用模式，写入有界队列（上限 50、30 天过期、超限归档）

依赖与降级：部分高阶功能对接私有辅助库（如 `/usr/local/lib/wk.sh`、统一推送入口）。开源版提供基础逻辑，外部环境可自行适配对应接口；依赖缺失时脚本打印警告并降级到本地日志/终端输出，不中断主流程。

## Usage（用法）

```bash
# 1. 安装配置模板并按本机修改
sudo install -Dm644 templates/ops.conf.example /etc/openclaw-ops/ops.conf

# 2. 试运行（所有清理类脚本均支持 --dry-run / 只读扫描）
./scripts/scratch-sweep.sh --dry-run
./scripts/ref-count.sh --list-zero
./scripts/exp-scan.sh --dry-run

# 3. 接入定时任务（示例见 cron/ops.cron.example）
```

环境变量：`OPS_CONF` 指定配置路径（无 root 场景）；`EXP_NO_NOTIFY=1` 关闭推送。

## 文档索引

| 文档 | 内容 |
|---|---|
| `docs/信息资产管理规范.md` | 5+1 类资产的字典体例管理规则（唯一位置/命名/保留/变更/检索键） |
| `docs/架构设计与复用体系.md` | 三层总纲结构与复用"上提门槛"设计（草案） |
| `docs/双机协作规范.md` | 编排端/执行端职责边界与脚本归宿规则 |
| `docs/规范-*.md`、`docs/巡检.md` | v1.0 基础运维各专项规范（文档/配置/备份/技能/记忆/日志/脱敏） |

English overview: [README.en.md](README.en.md). License: [LICENSE](LICENSE).
