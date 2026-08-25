# WeKnora 调研笔记：IM 集成、内网部署与生态互通

> **调研日期**：2026-08-24
> **代码基准**：WeKnora v0.7.2（本地代码库实测，所有代码引用均已逐一验证）
> **姊妹文档**：[WeKnora vs Dify vs RAGFlow vs FastGPT 对比](./WeKnora-vs-Dify-RAGFlow-FastGPT-对比.md)（四平台横向对比）
> **本文定位**：部署形态与集成方案的问答式调研结论，围绕"内网企业环境怎么用 WeKnora"展开。

---

## 目录

- [1. WeKnora 项目速览](#1-weknora-项目速览)
- [2. IM 全渠道集成](#2-im-全渠道集成)
- [3. 网络要求：不需要公网入站](#3-网络要求不需要公网入站)
- [4. 内网部署 + 外网 LLM：标准形态](#4-内网部署--外网-llm标准形态)
- [5. LLM 选型：智谱 Coding Plan 为什么不行](#5-llm-选型智谱-coding-plan-为什么不行)
- [6. 与腾讯生态产品的区别与互通](#6-与腾讯生态产品的区别与互通)
  - [6.1 WeKnora vs ima](#61-weknora-vs-ima)
  - [6.2 WeKnora 与 WorkBuddy 打通](#62-weknora-与-workbuddy-打通)
- [7. 推荐部署架构汇总](#7-推荐部署架构汇总)
- [8. 参考资料](#8-参考资料)

---

## 1. WeKnora 项目速览

**WeKnora** 是腾讯开源的企业级 AI 知识库框架（v0.7.2，MIT 协议，20.5k⭐），也是微信对话开放平台（chatbot.weixin.qq.com）的技术底座。

**三大核心能力**：

| 能力 | 说明 |
|---|---|
| RAG 快速问答 | BM25 + 向量 + GraphRAG + 父子分块等混合检索 |
| ReAct Agent | Think-Act-Observe-Finalize 循环，自主编排检索 / MCP 工具 / 网络搜索 |
| Wiki 模式 | Agent 自动把文档蒸馏成互链 Markdown 知识库 + 知识图谱，支持人工编辑、修订历史、行级 diff、一键回滚 |

**技术架构**：Go 1.26（Gin）后端 + Python（docreader 文档解析微服务，gRPC + TLS）+ Vue 3 前端 + 独立 Agent 沙箱容器。默认 PostgreSQL（ParadeDB：BM25 + 向量一体），向量库可换 8 种、对象存储可换 7 种、LLM 供应商 16+ 家。

**在四平台（vs Dify / RAGFlow / FastGPT）对比中的位置**：赢在知识治理（chunk 版本化编辑回滚）、IM 全渠道、企业管控全量开源、MIT 协议；短板是无可视化工作流编排、社区较年轻。详见姊妹文档。

---

## 2. IM 全渠道集成

### 2.1 是什么意思

**员工在钉钉 / 飞书 / 企业微信里直接 @机器人 提问，背后走的就是 WeKnora 知识库问答**——不需要写任何中间层代码，在后台创建通道、填入平台应用凭证即可。

WeKnora 内置 **10 个 IM 平台适配器**（`internal/im/adapter.go:11-30`）：

```
企业微信(WeCom) / 飞书(Feishu) / Lark(国际版，共用飞书适配器) / 钉钉(DingTalk)
Slack / Telegram / Mattermost / 微信(WeChat iLink) / QQBot / 云之家(Yunzhijia)
```

**消息流转**：

```
员工在钉钉群 @机器人："报销流程第三步是什么？"
    ▼
钉钉 Stream/Webhook ──► im/adapter（统一解析为 IncomingMessage）
    ▼
im/service ──► RAG 检索 / ReAct Agent ──► 生成答案
    ▼
流式分段回复到会话（支持思考过程、工具调用过程展示）
```

### 2.2 群聊完全支持（飞书群 / 企微群实测代码确认）

- **触发方式**：群里 **@机器人 + 问题**；私聊直接发消息（`feishu/adapter.go:7`、`wecom/webhook_adapter.go:4` 注释明确 "direct or @mention in group"）
- **@前缀剥离**：企微客户端不会自动去掉 @ 前缀，WeKnora 自行剥离并处理边界情况（双空格、机器人显示名自动学习，`wecom/longconn.go:746-805`）
- **会话隔离**：按 `(平台, 用户, 群, 租户)` 或 thread 绑定，群里每人独立多轮上下文，互不串话
- **引用追问**：引用机器人某条回复继续追问，被引内容自动作为上下文（`wecom/quote.go`）
- **富消息**：图片、文件消息可处理（发 PDF 可解析入库或作临时附件问答）
- **体验细节**：流式分段推送、思考/工具过程展示、QA 排队防乱序（`qaqueue.go`）
- **群内命令**：`/clear` 清会话、`/search 关键词`、`/stop` 停止生成、`/help`、`/info`

### 2.3 IM 能力小结

| 能力 | 状态 |
|---|---|
| 私聊问答 | ✅ |
| 群聊 @机器人问答 | ✅（飞书/企微/钉钉等全部支持） |
| 多轮上下文 / 引用追问 | ✅ |
| 图片 / 文件消息 | ✅ |
| 流式回答 + 过程展示 | ✅ |
| 斜杠命令 | ✅ |
| 需要自写中间层 | ❌ 不需要，配置凭证即用 |

> 对比：Dify / RAGFlow / FastGPT 均无内置 IM 渠道，接入需自研桥接或上企业版。

---

## 3. 网络要求：不需要公网入站

**逐渠道核实 `factory.go` 后的结论：绝大多数渠道默认就是"服务器主动往外连"的长连接模式，防火墙无需开放任何公网入站端口。**

| 渠道 | 默认模式 | 原理 | 需要公网入站？ |
|---|---|---|---|
| 钉钉 | **WebSocket**（Stream 模式） | 主动连钉钉 | ❌ |
| Slack | **WebSocket**（Socket Mode） | 主动连 Slack | ❌ |
| Telegram | **Long Polling** | 主动轮询拉取 | ❌ |
| QQBot | 仅 WebSocket | 主动连接 | ❌ |
| 微信（iLink） | **HTTP Long-Polling**（无 webhook） | 主动拉取 | ❌ |
| 企业微信 | 支持 LongConn 长连接 | 主动连接 | ❌ |
| 飞书 / Lark | 支持 LongConn 长连接 | 主动连接 | ❌ |
| 云之家 | 默认 Webhook，**可切 WebSocket** | 二选一 | ⚠️ 切 WS 后不需要 |
| Mattermost | 仅 Webhook | 被动接收 | ✅（但 Mattermost 通常自建内网，内网互通即可） |

**真正需要的是出站（outbound 443）**：IM 平台 WebSocket、LLM API、（可选）数据源同步与外置搜索。

**仅以下三种情况才需要公网入站**：
1. Web UI / API 提供给外网用户
2. 主动选择 Webhook 模式（运维偏好）
3. 网站嵌入 Widget 发布到公网页面

> WeKnora 官方安全建议也是内网/私网部署——"长连接优先"正是为此设计。

---

## 4. 内网部署 + 外网 LLM：标准形态

### 4.1 架构

```
┌───────────────── 公司内网 ─────────────────┐
│                                            │
│  员工 ◄──► 飞书/钉钉群（内网办公即可）        │
│                                            │
│  WeKnora 服务器                             │
│  ├─ app / docreader / sandbox / 前端        │
│  ├─ PostgreSQL / Redis（数据全落内网）        │
│  │                                         │
│  ══ 出站 443（唯一对外通道）══                │
└──┼─────────┬─────────┬─────────────────────┘
   ▼         ▼         ▼
 飞书 WS   LLM API   （可选）搜索/数据源
```

- **数据边界**：知识库存储、检索、会话记录全在内网
- **注意**：提问涉及的文档片段会作为 prompt 发给所选的外部 LLM API（合规上等于"数据出境到模型厂商"）

### 4.2 出站代理支持（企业内网刚需，代码已验证）

LLM 调用的 HTTP transport **显式支持标准代理环境变量**（`internal/models/chat/transport.go:52`）：

```go
var rawHTTPTransport = &http.Transport{
    Proxy: http.ProxyFromEnvironment,  // HTTP_PROXY / HTTPS_PROXY
    ...
}
```

- 内网不能直连公网时：容器设 `HTTPS_PROXY=http://代理:端口` 即可
- 网页搜索还支持**按搜索源单独配 `proxy_url`**（`internal/types/web_search_provider.go:87`），比全局代理更精细

### 4.3 防火墙白名单清单（很短）

| 用途 | 目标 |
|---|---|
| LLM | 所选厂商 API 域名（如 `api.deepseek.com`、`open.bigmodel.cn`、`dashscope.aliyuncs.com`…） |
| 飞书 | `open.feishu.cn`（Lark: `open.larksuite.com`） |
| 网页搜索（可选） | 用本地 SearXNG 则无需出站 |
| 数据源同步（可选） | Notion / 语雀 API |

### 4.4 数据敏感度分层建议

- 一般内容（制度、产品手册）→ 任意 LLM 供应商
- 敏感内容 → 优先国内厂商（DeepSeek / Qwen / 混元 / 智谱，WeKnora 对国产模型支持全面）
- 高度敏感 → 后续内网补 Ollama / vLLM，WeKnora 支持多模型并存、按知识库/Agent 指定不同模型，届时把敏感库切到内网模型
- LLM API Key 落库走 AES-256-GCM 加密

---

## 5. LLM 选型：智谱 Coding Plan 为什么不行

**问题**：能否用智谱 GLM Coding Plan（订阅制套餐）作为 WeKnora 的 LLM 后端省钱？

### 结论：技术上能连，条款明确禁止，不要这么做

**技术层面 ✅**：WeKnora 的 Anthropic provider 支持自定义 BaseURL（`internal/models/chat/anthropic.go:92-104`），配置 Anthropic 类型 + 智谱 Anthropic 兼容端点 + Key 即可跑通。

**条款层面 ❌**（智谱官方文档原文）：

> "GLM Coding Plan 仅限在官方支持的指定工具与产品环境中使用，用户不得将订阅权益用于以下范围之外的工具或场景。"

- 指定工具清单：ZCode、Claude Code、Codex、OpenCode、TRAE、CodeBuddy、灵码、Qoder 等——**全是编程工具**
- 后果：用于非支持工具 → 限制权益；违规触发风控 → 限流、冻结；**3 次以上违规可能封禁账号**
- WeKnora 的 RAG 流量特征（长文档 prompt、多轮会话、持续并发）与编程工具差异巨大，易被风控识别

### 正确做法：智谱标准按量 API

| | Coding Plan | 标准 API（推荐） |
|---|---|---|
| 用途限制 | 仅指定编程工具 | 任意应用 |
| WeKnora 接入 | 需绕协议，有封号风险 | **智谱是内置供应商**，填 Key 即用 |
| RAG 场景 | 额度按编程 prompt 设计，很快耗尽 | 按 token 计费，GLM 系列价格低 |

---

## 6. 与腾讯生态产品的区别与互通

### 6.1 WeKnora vs ima

两者都是腾讯"知识库 + AI"产品，但是**两类东西**：

> **ima = 个人 AI 知识管家**（SaaS App，开箱即用，数据在腾讯云）
> **WeKnora = 企业知识工程平台**（开源框架，私有化部署，一切可定制）

| 维度 | ima | WeKnora |
|---|---|---|
| 形态 | SaaS：客户端 + 小程序 | 开源框架：Docker/K8s 私有化 |
| 用户 | 个人 / 学生 / 轻办公 | 企业 IT / 开发者 |
| 定位 | "搜读写"智能工作台（知识消费 + 写作） | 知识工程（RAG + Agent + Wiki + 治理） |
| 知识来源 | 个人文件（19 种格式）、网页、**微信聊天文件/公众号** | 企业文档批量入库、飞书/Notion/语雀/RSS 自动同步、API/MCP 程序化写入 |
| 模型 | 锁定混元 + DeepSeek | 20+ 供应商任意换（含本地 Ollama） |
| Agent | 基本无 | ReAct + MCP + 搜索 + 沙箱 Skills |
| 知识治理 | 个人库 + 共享库 | chunk 版本编辑/回滚、Wiki 修订历史、RBAC、审计 |
| 数据主权 | 腾讯云托管 | 完全私有 |
| 费用 | 免费 + 增值 | 免费开源（自付基础设施 + LLM） |

**微信生态切入点不同**：ima 整合**个人微信内容侧**（导入聊天文件、公众号文章）；WeKnora 整合**企业触达侧**（企微机器人、微信对话开放平台、小程序）。

**选型**：个人资料管理 → ima；企业知识服务 → WeKnora；两者不互斥，常见格局是"员工个人用 ima，企业知识用 WeKnora"。

### 6.2 WeKnora 与 WorkBuddy 打通

**能打通，协议层现成咬合**：WorkBuddy（腾讯云效率智能体工作台）插件中心支持"基于 MCP SSE 新建工具"接入已部署的 MCP Server，也支持 API 插件；WeKnora 官方 MCP Server（PyPI 包 `tencent-weknora-mcp`）支持 stdio / SSE / HTTP 传输，网络传输自带 auth token 鉴权。

#### 方式一：MCP（推荐）

```
WorkBuddy 智能体（腾讯云）
    ▼ 调用工具
插件中心 → 新建 MCP 工具 → 填 WeKnora MCP Server SSE 地址 + auth token
    ▼
WeKnora MCP Server ──► WeKnora REST API（作用域 API Key）
    ▼
知识库 / RAG / Agent
```

步骤：① MCP Server 以 SSE/HTTP 模式部署；② WeKnora 后台建**作用域 API Key**（只授检索/问答、可限定知识库）；③ WorkBuddy 填地址和 token。

**打通后 WorkBuddy 智能体可用的能力**（MCP Server 29 工具，`mcp-server/weknora_mcp_server.py`）：
- 检索问答：`hybrid_search`、`chat` / `agent_chat`（带引用的答案）
- 知识写入：`create_knowledge_from_file / from_url / from_text`（工作流产出自动沉淀进知识库）
- 知识库 / 会话 / Agent 管理

典型分工：**WorkBuddy 做流程编排执行，WeKnora 做企业知识存储/检索/治理**——执行中随时查知识、产出自动归档成知识。

#### 方式二：REST API 直连

WorkBuddy 以 API 插件调用 WeKnora ~360 个端点（作用域 API Key 鉴权）；`resource_urls=public` 返回可直接渲染的文件 URL，便于引用原文展示。

#### 网络可达性（关键约束）

**方向决定网络**：WorkBuddy 是云端 SaaS，无论 MCP 还是 REST，"云端 → 你"方向必须可达。但"公网可达"≠"公网部署"——**只暴露一个 API 入口，不是把系统搬到公网**：

```
                    ┌────────────── 你的内网 ──────────────┐
WorkBuddy(腾讯云)    │  nginx 网关：只转发 /api/*            │
    │  HTTPS        │   + IP 白名单（仅腾讯云 WorkBuddy 段）  │
    ▼               │  WeKnora：作用域 API Key（能力级+KB 级）│
 API 入口 ──────────►│   Web UI / 管理后台 ──► 仅内网         │
                    │   IM 长连接 ──► 出站，无需暴露          │
                    │   PG / Redis ──► 完全内网              │
                    └──────────────────────────────────────┘
```

防护叠加：HTTPS + IP 白名单 + 作用域 API Key（能力级授权 + per-KB 限制 + 限流 + 最后使用跟踪）+ 管理面留在内网。

**完全不想开公网入站的替代方案**：

| 方案 | 做法 | 适用 |
|---|---|---|
| 反向代理最小暴露 | nginx 只暴露 `/api/*` + IP 白名单 | 有 DMZ/边界网关经验（最常规） |
| 出站隧道 | frp / Cloudflare Tunnel，内网主动建隧道，**零入站端口** | 安全要求严 |
| 腾讯云专线/云联网 | VPC 打通后走内网级链路 | 已接腾讯云专线（问网络组） |
| 先验证再联通 | 暂不打通，先在内网验证知识库价值 | 试水阶段 |

---

## 7. 推荐部署架构汇总

综合本次全部调研，目标形态（内网企业环境）：

```
┌─────────────────────────── 公司内网 ───────────────────────────┐
│                                                                │
│  员工日常入口：飞书群/企微群 @机器人 ──► 流式回答（带知识库引用）    │
│  管理员入口：内网 Web UI（RBAC + 审计）                           │
│                                                                │
│  WeKnora（Docker Compose / K8s）                                │
│  ├─ app + docreader + sandbox + frontend                        │
│  ├─ PostgreSQL（ParadeDB：BM25+向量）+ Redis                    │
│  ├─ SearXNG（本地搜索，不出站）                                   │
│  │                                                             │
│  ═══ 出站 443（唯一对外通道，可走 HTTPS_PROXY 代理）═══            │
│     ├─► 飞书/企微 WebSocket（IM 长连接，零入站端口）               │
│     └─► LLM 标准 API（智谱/DeepSeek/Qwen/混元，按量付费）         │
│                                                                │
│  （可选）WorkBuddy 互通：网关只暴露 /api/* + IP 白名单 + 作用域 Key │
│  （可选）数据沉淀：WorkBuddy 产出经 MCP 自动入库                    │
└────────────────────────────────────────────────────────────────┘
```

**核心结论清单**：

1. ✅ IM 全渠道（含飞书群/企微群 @机器人）开箱即用，无需写代码
2. ✅ 全部主流 IM 渠道支持长连接/轮询，**不需要公网入站**
3. ✅ 内网部署 + 外网 LLM 是标准形态，支持 `HTTPS_PROXY` 企业代理出站
4. ⚠️ 智谱 Coding Plan 技术能连但**条款禁止**（风控可封号），用标准按量 API
5. ✅ ima 是个人产品、WeKnora 是企业平台，定位互补不冲突
6. ✅ 与 WorkBuddy 经 MCP（推荐）或 REST API 打通；仅需暴露最小 API 入口，或走隧道/专线零入站
7. ⚠️ 数据合规：文档片段会发给所选 LLM 厂商，敏感内容选国内厂商或后续加内网模型

---

## 8. 参考资料

- **WeKnora**
  - GitHub：<https://github.com/Tencent/WeKnora>（v0.7.2）
  - 官网：<https://weknora.weixin.qq.com>
- **智谱**
  - GLM Coding Plan 使用须知（条款限制）：<https://docs.bigmodel.cn/cn/coding-plan/usage-notes.md>
  - 接入工具（指定工具清单）：<https://docs.bigmodel.cn/cn/coding-plan/tool/others.md>
- **ima**
  - 官网：<https://ima.qq.com/>
  - 腾讯云文档：<https://cloud.tencent.com/document/product/1831/134397>
- **WorkBuddy / 腾讯云智能体**
  - WorkBuddy 产品技术概览与多平台集成指南：<https://cloud.tencent.com/developer/article/2680488>
  - 基于 MCP 新建工具（腾讯云文档）：<https://cloud.tencent.com/document/product/1759/117855>
  - 产品动态（MCP SSE 接入）：<https://cloud.tencent.com/document/product/1759/104191>
  - 腾讯云发布效率智能体工具集（新华网）：<http://www.news.cn/tech/20260605/e410f96e4f594ec0b92a4054faed70de/c.html>

---

*本文档由 WeKnora v0.7.2 本地代码库实测 + 官方文档核实整理，数据截至 2026-08-24。*
