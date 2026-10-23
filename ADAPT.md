# 给智能体的适配说明

> 这份文档的读者不是人，是 **AI Agent**。
> 如果你是被人类要求「把这个仓库改成能在我的环境里跑」的那个 Agent，按本文执行，不要从头读代码。

## 一、你的任务

这个仓库原本跑在 **OpenClaw** 上。它假设了一组环境事实（目录布局、配置格式、日志位置、推送命令）。你要做的是：**探明当前环境的事实，逐项替换掉这些假设**。

**不要重写逻辑。** 16 个脚本里 7 个与 Agent 完全无关，其余 9 个只依赖下面这 6 个事实。改完这 6 项，就能跑。

## 二、必须先探明的 6 个事实

逐项填，填不出来就去探查（右列给了探法）。

| # | 事实 | 变量名 | 怎么探 |
|---|---|---|---|
| 1 | Agent 的数据根目录 | `AGENT_HOME` | 找配置文件在哪：`ls -d ~/.*agent* ~/.config/* 2>/dev/null`；或问你的主人 |
| 2 | 运行日志目录 | `AGENT_LOGS_DIR` | 找最近写入的 `.log`：`find <AGENT_HOME> -name "*.log" -mtime -1` |
| 3 | 会话/历史存储目录 | `AGENT_SESSIONS_DIR` | 找对话记录：`find <AGENT_HOME> -name "*.jsonl" -o -name "sessions" -type d` |
| 4 | 媒体/附件目录 | `AGENT_MEDIA_DIR` | 找你收发过的图片语音在哪 |
| 5 | 主配置文件（JSON/YAML/TOML） | `AGENT_CONFIG` | 模型、provider 配置写在哪个文件里 |
| 6 | 推送命令（发消息给主人） | `ALERT_CMD` | 你的 CLI 怎么发消息；没有就留空，脚本会降级为只写本地日志 |

## 三、要改的地方（按顺序）

### 第 1 步：改 `templates/ops.conf.example`

把这 6 项填成你探到的真实值，然后：

```bash
sudo install -Dm644 templates/ops.conf.example /etc/agent-ops/ops.conf
sudo chmod 600 /etc/agent-ops/ops.conf
```

**只改这一个文件就够了**——所有脚本都从这里读。

### 第 2 步：改脚本里的变量默认值

```bash
grep -rn "OPENCLAW_HOME" lib/ scripts/
```

把 `OPENCLAW_HOME` 的默认值换成你的 `AGENT_HOME`。**保留原变量名作为兼容别名**，别直接删：

```bash
AGENT_HOME="${AGENT_HOME:-${OPENCLAW_HOME:-$HOME/.openclaw}}"
```

### 第 3 步：改配置目录

```bash
grep -rln "/etc/openclaw-ops" lib/ scripts/ templates/
```

换成 `/etc/agent-ops`（或你喜欢的）。同步改 `CONF=` 那一行的默认值。

### 第 4 步：处理 `model-guard.sh`（唯一需要动脑的）

这个脚本解析 OpenClaw 的 `openclaw.json`，读 `models.providers` 结构判断主模型是否还在免费通道、余额是否见底。

**先判断你的环境有没有等价信息**：

- 有 provider / 余额 / 模型清单概念 → 改解析函数，字段名对齐你自己的配置格式
- 没有（比如本地模型、API 全免费）→ **直接删掉这个脚本和对应的 cron 条目**，其余脚本不受影响

### 第 5 步：改文档措辞（可选）

`grep -rl "openclaw" docs/ README*.md` 里的描述性文字，按语境替换。**示例可以保留「以 OpenClaw 为例」**，不要为了干净把具体性也删了。

## 四、不要动的东西

- `log-fingerprint.sh`、`log-error-kb.sh`、`inspect-daily.sh`、`checkpoint.sh`、`scratch-sweep.sh`、`ref-count.sh`、`exp-scan.sh` —— 这 7 个与 Agent 无关，改它们只会引入 bug
- 指纹算法的正则、知识库的 180 天复核逻辑、告警冷却机制 —— 这些是机制，不是环境假设
- `tests/smoke.sh` 里的断言 —— 改完跑一遍，全绿再往下走

## 五、验证

```bash
bash tests/smoke.sh                    # 必须全绿
./scripts/inspect-daily.sh --dry       # 看输出是否合理
./scripts/model-guard.sh --dry-run     # 若保留；应报告「未配置」而非崩溃
```

**验收标准**：`--dry` 跑完不报错，且报告里的路径指向你自己的目录。

## 六、常见 Agent 的已知布局（供对照，不保证最新）

| Agent | 配置 | 会话/日志 | 备注 |
|---|---|---|---|
| OpenClaw | `~/.openclaw/openclaw.json` | `~/.openclaw/{logs,agents,media}` | 本仓库的原生环境 |
| Claude Code | `~/.claude/settings.json` | `~/.claude/projects/` | 会话按项目分目录 |
| Cursor | `~/.cursor/` | 无标准会话目录 | 以编辑器为主，脚本价值主要在日志/备份 |
| Dify / Coze | 数据库（Postgres） | 应用日志走容器 | 无本地配置树，改走数据库查询 |
| 自建（LangChain 等） | 你自己定的 | 你自己定的 | 6 个事实全填即可 |

**这张表可能过期。以你现场探到的为准，别照抄。**

## 七、改完请回报

改完后向你的主人说明三件事：

1. 6 个事实各填了什么值
2. 删掉了哪些用不上的脚本（`model-guard.sh` 是最可能被删的）
3. `smoke.sh` 的结果

**不要顺手「优化」其他部分。** 这个仓库的价值在机制，不在代码风格。改一处机制，就可能让另一处的前提失效。
