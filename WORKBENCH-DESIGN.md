# Enter输入法 · 缓冲工作台（Workbench）产品方案与架构设计

版本：v0.1 草案 · 2026-07-16
状态：待评审
上游输入：`new-rime.pen` 七张探索稿（wBwdM/XKzFo/e9aJFL/FBS3A/rulod/BMbRV/S0d7w）+ 产品负责人 2026-07-16 口头需求收敛
关系：本文档是新一版的**权威方案**；`new-rime.pen` 降级为视觉参考；`ARCHITECTURE.md` 仍是 P1 时代交接文档（已滞后），两者冲突时以本文档为准。

---

## 0. 一句话定位

把 Enter输入法从「Rime 提交的暂存队列」升级为**上屏前的文本工作台**：本地打字、外部数据源（MCP / HTTP / SSE / SSH / 配对设备）、内置加工（翻译 / AI），全部汇入同一个缓冲区，经人工确认后投递——**共用同一套三层面板 UI**。

产品负责人拍定的六条需求（本方案的边界即由此划定）：

1. 缓冲区模式新定义：**中间是缓冲区，下方是本地打字候选词区，上方是外部数据源**
2. 本地智能体用 **MCP** 把文字传给输入法
3. 输入法**内置翻译**
4. 输入法可通过 **SSE / SSH / HTTP** 从外部获取文字
5. 输入法**内置 AI 能力**
6. 设备间传字（隔空传字）保留，**交互统一进同一套 UI**

### 0.1 明确不做（v1 边界）

| 砍掉 | 理由 |
|---|---|
| 剪贴板粘贴捕获 | 不在需求清单里；收益/风险比全套最差（输入法读用户从别处复制的内容），设计稿自己都标了警告色 |
| AirDrop 投递目标 | 不在需求清单里；延后 |
| Turn/Artifact 完整版本模型（revision/derivedFrom/分叉） | 探索稿里最贵的部分；v1 用「结果块」轻量替代，版本化留给需求被验证之后 |
| 投递撤回（revoke） | 依赖版本模型与协议大改；延后 |
| 手动编辑缓冲块 | BufferModel 当初刻意砍掉 diff/reconcile（append-only），v1 不推翻；块级操作限于 删除/重排/发送 |
| 「实时镜像」预设 | 探索稿自己标注"高级预设；默认关闭"；v1 由投递目标开关覆盖此语义 |

---

## 1. 产品定义

### 1.1 三层面板（唯一交互面）

```
┌────────────────────────────────────────────────┐
│ ① 传入轨  远端·MacBook Pro ⋯  AI消息  待接收 3   │  ← 外部数据源（新）
├────────────────────────────────────────────────┤
│ ② 缓冲轨  [朋友][晚点][shij|] 翻译1.2s ⏹ ➤ ⤢    │  ← 缓冲区（升级）
├────────────────────────────────────────────────┤
│ ③ 候选区  1.时间 2.实践 3.事件 …                 │  ← 本地打字（现状保留）
└────────────────────────────────────────────────┘
```

实现载体：现有 `CandidateWindow` 的根竖排 stack。今天它已经是「BufferInlineView + preedit + 候选条」的组合，本方案在最上方加一条**传入轨**，并把 BufferInlineView 升级为带处理状态与来源徽标的**缓冲轨**。不新开窗口，不改 NSPanel 行为（nonactivating、跟随 caret 定位、lastGoodRect 兜底逻辑全部保留）。

各层职责：

- **① 传入轨（InboundRail，新增）**：每个活跃外部来源一个胶囊（图标 + 名称 + 活动状态动画），右端「待接收 N」计数。点胶囊/计数展开待决列表：逐条 接受→进缓冲区 / 拒绝→丢弃。无活跃来源且无待决条目时**整条隐藏**（普通打字场景与今天视觉零差异）。
- **② 缓冲轨（ChunkRail，升级）**：现有 chips + preedit + 插入光标不变；新增（a）每个块的**来源徽标**（rime 块无徽标保持干净，外来/结果块带色点：翻译=蓝、AI=绿、远端=紫、MCP=橙）；（b）处理中胶囊（spinner + "翻译 1.2s"计时）；（c）**结果块**——处理器产出，样式区别于普通块，默认标记为「待发送」；（d）右端控制键从 2 键变 3 键：**停止**（中止在途任务，仅有任务时出现）、**发送**（保留按住 1.2s 全发的现有手势与进度动画）、**清空**（保留，语义与停止分开）。
- **③ 候选区**：不动。本次范围外（矩阵翻页等已在 0.4.3 完成）。

### 1.2 用户故事（验收场景）

1. **打字暂存**（现状不回归）：缓冲模式下打字 → 块进缓冲轨 → Enter 短按逐块上屏 / 长按 1.2s 全发。传入轨不出现。
2. **智能体推稿**：Claude Code / Codex 通过 MCP 调 `buffer_push` → 传入轨亮起「MCP · <来源名>」+ 待接收 +1 → 用户点接受 → 成为带橙色徽标的块 → Enter 上屏到微信输入框。
3. **翻译**：选中/框选缓冲区里的块 → 点「翻译」→ 处理胶囊转圈计时 → 结果块出现（原块保留）→ 用户按 Enter 发结果块。
4. **AI 润色**：同上，处理器换成 AI；SSE 流式期间**只更新同一个结果块**的文字，不产生逐 token 的碎块。
5. **隔空传字（收）**：配对 Mac 发来文字 → 不再直接上屏，进传入轨待决 → 接受后成为紫色徽标块 → 手动发送。（发送侧行为见 §6。）
6. **安全底线**：焦点在密码框（系统 secure input 生效）时，发送/接受按钮禁用并显示锁标；缓冲区任何内容不会被投递。

### 1.3 交互不变量（安全叙事，恒真，不做成开关）

- **一切外部文字先进传入轨待决，绝不自动进缓冲区**（可按来源信任等级降为自动进入缓冲区，但**永不**自动上屏）。
- **一切处理器结果先回缓冲区成为结果块**，绝不直接上屏。
- **上屏只由用户的 Enter/发送动作触发**。
- **secure input 激活时投递路径整体禁用**。

---

## 2. 领域模型

拆掉「Block 既是位置又是内容」的混合体，但只拆到 v1 需要的粒度：

```swift
/// 文字从哪来。既驱动 UI 徽标，也驱动 echo 防回环与门控。
enum Origin: Equatable, Codable {
    case rime                          // 本地打字（无徽标）
    case mcp(client: String)           // MCP 客户端名（智能体自报 + token 绑定）
    case http(source: String)
    case sse(feed: String)
    case ssh(host: String)
    case remotePeer(deviceID: String)  // 配对 Mac
    case marine                        // 兼容期；迁移完成后并入 .mcp
    case processor(kind: ProcessorKind, jobID: UUID)  // 翻译/AI 结果块
}

/// 缓冲区的一个块。position 由数组顺序表达，内容与来源在块内。
struct Chunk: Identifiable {
    let id: UUID
    var text: String
    let origin: Origin
    let createdAt: Date
    var role: Role = .ordinary
    enum Role { case ordinary          // 普通块（含已接受的外来块）
                case result(jobID: UUID, delivered: Bool) }  // 处理器结果块
}

/// 传入轨上的待决条目。
struct InboundItem: Identifiable {
    let id: UUID
    let origin: Origin
    var title: String?                 // 来源可自带标题（如 Marine 的 kind）
    var text: String
    var streaming: Bool                // SSE/MCP 流式条目：text 原位更新
    var state: State = .pending
    enum State { case pending, accepted, rejected }
}

/// 一次处理器运行。
struct TransformJob: Identifiable {
    let id: UUID
    let processor: ProcessorKind       // .translation(config) / .ai(config)
    let inputSnapshot: String          // 冻结的输入文本（选中块拼接）
    let sourceChunkIDs: [UUID]
    var state: State = .queued
    enum State { case queued
                 case running(startedAt: Date)
                 case succeeded(resultChunkID: UUID)
                 case failed(message: String)
                 case cancelled }
}

/// 投递流水（轻量账本）。远端目标记录 ack。
struct DeliveryRecord {
    let messageID: UUID
    let target: DeliveryTarget
    let chunkIDs: [UUID]
    let sentAt: Date
    var status: Status
    enum Status { case inserted        // 本地 insertText 已调用
                  case acked           // 远端已确认（协议 v2）
                  case failed(String) }
}
```

设计要点：

- **`Origin` 是这次重构的第一等公民**。它同时解决三件事：UI 来源徽标、echo 防回环（§6.3）、来源门控（§4.4）。探索稿里 Marine `Draft.kind` 在入口被丢弃的 bug 由 `InboundItem.title` 承接。
- **结果块就是 Chunk**（`role: .result`），不另设 ArtifactStore。发送、删除、清空对它一视同仁——这是「交互用同一套 UI」在数据层的对应物。
- **`inputSnapshot` 即轻量版「Turn 冻结」**：任务启动时拷贝文本快照，之后用户继续打字不影响在途任务。不引入显式 Turn 实体。

---

## 3. 总体架构

```
                       ┌──────────────────────────────────────────────┐
 外部世界               │              ETInput 进程                     │
                       │                                              │
 Claude/Codex ──MCP──▶ ┌──────────────┐                               │
 curl/脚本 ──HTTP──▶   │ LocalGateway │─┐                             │
 服务器推送 ──SSE──▶    │ (127.0.0.1)  │ │                             │
                       └──────────────┘ │   ┌──────────┐  ┌─────────┐ │
 远程主机 ◀──SSH命令── SSHProvider ──────┼──▶│InboundBus│─▶│传入轨 UI │ │
 配对Mac ◀─AES-GCM──▶ RemotePeerProvider┘   │ (门控)    │  └────┬────┘ │
                       ┌──────────────┐     └──────────┘   接受 │      │
 Marine(兼容期) ─轮询─▶ │MarineProvider│──────────▲              ▼      │
                       └──────────────┘          │        ┌──────────┐ │
                                                 │        │BufferCore│ │
 OpenAI兼容API ◀─SSE─┐ ┌───────────┐  结果块回写  │        │ (chunks) │ │
 Apple翻译(本地)◀────┼─│ JobRunner │─────────────┘        └────┬─────┘ │
                     │ │ (actor)   │◀───选中块+处理器──────────┘ │      │
                     │ └───────────┘        Enter/发送           ▼      │
                     │                                    ┌───────────┐│
                     │                                    │ Delivery  ││
                     │                                    │ Router    ││
                     │                                    └─┬───────┬─┘│
                     │                    当前输入框(主,默认)│       │远端(次,opt-in)
                     └──────────────────── insertText ◀────┘       └──▶ 配对Mac
```

### 3.1 模块与文件规划

| 模块 | 新/改 | 文件 | 职责 |
|---|---|---|---|
| BufferCore | 改（自 BufferModel 演进） | `BufferModel.swift` → 渐进重构 | chunks 存储、插入点、结果块、状态广播 |
| InboundBus | 新 | `Inbound/InboundBus.swift` | 汇聚所有 provider，执行门控，产出 InboundItem |
| SourceProvider 协议 | 新 | `Inbound/SourceProvider.swift` | `start()/stop()`、事件回调、健康状态 |
| LocalGateway | 新 | `Inbound/LocalGateway.swift` | 本地 HTTP 服务器：MCP + HTTP push + 管理端点 |
| MCP 实现 | 新 | `Inbound/MCPServer.swift` | streamable HTTP transport 上的 MCP 会话与 tools |
| SSEClientProvider | 新 | `Inbound/SSEClient.swift` | 订阅外部 SSE URL |
| SSHProvider | 新 | `Inbound/SSHProvider.swift` | `/usr/bin/ssh` 子进程流式读取 |
| RemotePeerProvider | 改 | `Remote/RemoteTypingService.swift` | 入站文字改道 InboundBus；协议 v2 加 ack |
| MarineProvider | 改（包装） | `MarineBridge.swift` | 包成 SourceProvider，恢复 kind 字段；迁移期后删除 |
| JobRunner | 新 | `Processors/JobRunner.swift` | actor；任务队列、进度、取消 |
| Processor 协议 | 新 | `Processors/Processor.swift` | `run(input, onPartial) async throws -> String` |
| TranslationProcessor | 新 | `Processors/TranslationProcessor.swift` | Apple Translation（macOS 15+，见 §5.2 风险） |
| AIProcessor | 新 | `Processors/AIProcessor.swift` | OpenAI 兼容 chat/completions，SSE 流式 |
| DeliveryRouter | 新（自 Delivery 演进） | `Delivery.swift` → `Delivery/DeliveryRouter.swift` | 多目标、echo 防回环、DeliveryRecord |
| 三层面板 | 改 | `CandidateWindow.swift` + `BufferInlineView.swift` + 新 `InboundRailView.swift` | §1.1 |
| 设置窗 | 改 | `SettingsWindow.swift` | §8 新 IA |

### 3.2 并发模型（现有代码最硬的墙，正面拆）

现状：`BufferModel.deliver` 是**同步闭包** `((String) -> Bool)?`，`sendAll/sendNextBlock` 同步判定成败；`BufferModel.swift` 与 `Delivery.swift` 中 async/await/Task 出现 0 次。翻译和 LLM 必然异步，塞不进这个形状。

拆法（三条规则，不引入第四条）：

1. **UI 与 IMK 全部 `@MainActor`**。BufferCore、InboundBus 的对外表面是 main-actor 的——IMKit 回调、NSPanel 渲染本来就在主线程，维持现状最省事也最不容易错。
2. **JobRunner 是 `actor`**，每个 TransformJob 一个 `Task`。运行中通过 `onPartial` 回调把流式片段 `await MainActor.run` 回写结果块；结束/失败/取消同理。取消 = `task.cancel()` + provider 侧关闭连接。
3. **投递保持同步**。`insertText` 本来就是主线程同步调用；处理器在**入缓冲区侧**跑（结果块先落缓冲区），投递时不再有任何异步依赖——这就是探索稿「安全门控恒真」的架构化表达，也顺带绕开了同步 deliver 的死结。**处理器在缓冲区跑，不在投递路径上跑**，是本方案与探索稿管线图唯一的刻意偏差（稿子画的是 缓冲区→处理器→投递 串联）。

Provider 侧：LocalGateway/SSE/SSH 各自持有独立 Task/连接，产出统一经 `InboundBus.submit(item)`（main-actor）进入。

---

## 4. 来源层（需求 2、4、6）

### 4.1 LocalGateway：一个本地 HTTP 服务器养三个协议

MCP（streamable HTTP transport）、HTTP push、SSE 管理流共用一个监听器：`127.0.0.1:47700`（可配置），基于 Network.framework `NWListener` 手写极简 HTTP/1.1（支持 keep-alive、chunked 响应）。**不引入 SwiftNIO**——本工程当前零 SPM 依赖（Package.swift 只有本地 target），Remote 模块已有在 NWConnection 上手写帧协议的先例；若后续端点膨胀再考虑换底座。

鉴权：所有端点要求 `Authorization: Bearer <token>`。token 生成后写入 `~/Library/RimeBuffer/gateway-token`（0600，与 RemoteIdentity 的既有决策一致——**不用 Keychain**，因为 ad-hoc 签名下 Keychain ACL 每次重装都会弹窗，这是 `RemoteIdentity.swift:12-15` 已论证并踩过的坑；拿到 Developer ID 正式签名后整体迁移 Keychain，此处与 §5.3 AI 凭据同一策略）。设置页提供「重新生成 token」与一键复制接入配置。

端点：

```
POST /mcp                    MCP streamable HTTP（初始化/工具调用/通知）
GET  /mcp                    MCP SSE 下行流（服务器→客户端通知）
POST /v1/inbound             裸 HTTP push：{text, title?, source?, stream_id?, done?}
GET  /v1/health              健康检查（无鉴权，只回版本号）
```

### 4.2 MCP tools（面向 Claude Code / Codex 等本地智能体）

```
buffer_push(text, title?, kind?)        → {item_id}   推一条待决条目到传入轨
buffer_stream_begin(title?)             → {stream_id} 开一个流式条目（占位卡片）
buffer_stream_append(stream_id, delta)  → {}          原位追加文字（不产生新条目）
buffer_stream_end(stream_id)            → {}          标记完成，条目变为可接受
buffer_pending()                        → {items:[…]} 列出自己推送的待决条目状态
```

刻意**不提供**：读取用户缓冲区内容、读取当前输入框上下文、触发投递的任何工具。智能体只能「给」，不能「看」不能「发」——这是隐私边界，写死，不做开关。

客户端接入（写进 README）：

```bash
claude mcp add --transport http etinput http://127.0.0.1:47700/mcp \
  --header "Authorization: Bearer $(cat ~/Library/RimeBuffer/gateway-token)"
```

### 4.3 其余 provider

| Provider | 形态 | v1 范围 |
|---|---|---|
| **HTTPProvider** | 被动收 `POST /v1/inbound`（脚本/curl 场景） | 与 MCP 共用 LocalGateway 与门控 |
| **SSEClientProvider** | 主动订阅用户配置的 URL 列表；`data:` 行追加进同一流式条目，`event: done` 收口 | 断线指数退避重连；每 feed 一个传入轨胶囊 |
| **SSHProvider** | `Process` 跑 `/usr/bin/ssh <host> <command>`，stdout 逐行流式进条目 | 认证完全依赖用户 `~/.ssh` 配置与 ssh-agent，**输入法不管理任何 SSH 密钥**；默认关闭，高级功能 |
| **RemotePeerProvider** | 现有 X25519+AES-GCM 通道，**入站改道**：收到 text 不再直接 insertText，产出 InboundItem | 协议 v2，见 §6.4 |
| **MarineProvider** | 现有轮询原样包装；`Draft.kind` 传入 `InboundItem.title`（修复字段蒸发） | 迁移期方案；Marine 改用 MCP push 后删除此 provider 与 etinput-runtime.json 握手 |

### 4.4 来源门控（传入轨的准入策略）

每来源一档信任等级，存 UserDefaults：

| 等级 | 行为 |
|---|---|
| **询问**（默认） | 条目进传入轨待决，用户逐条接受/拒绝 |
| **信任** | 条目直接进缓冲区成为块（仍绝不自动上屏，§1.3 不变量兜底） |
| **拦截** | 静默丢弃，传入轨计数器闪一下作提示 |

无有效 token 的请求在 HTTP 层直接 401，不进任何 UI。MCP 客户端名与 token 绑定记录，传入轨胶囊显示自报名称。

---

## 5. 处理器层（需求 3、5）

### 5.1 Processor 协议与 JobRunner

```swift
protocol Processor {
    var kind: ProcessorKind { get }
    func run(_ input: String,
             onPartial: @escaping (String) -> Void) async throws -> String
}
```

- 入口：用户在缓冲轨选中块（或默认全部普通块）→ 点处理器按钮 → JobRunner 建 job，`inputSnapshot` 冻结。
- 流式：`onPartial` 每次携带**全量已生成文本**（不是 delta），主线程原位更新结果块——「SSE 只更新同一个结果卡片，不产生 token blocks」由此保证。
- 并发上限 1（同一时刻一个 job，后来者排队）；缓冲轨处理胶囊显示 job 名 + 已用秒数；停止键 `task.cancel()`。
- 失败：结果块不产生，处理胶囊变红显示错误一行，点击展开详情；原块无损。
- 复用现有骨架：transient loading 三件套（`beginTransientLoading/appendMarineDraft/failTransientLoading`）是全工程唯一「异步产出→加载态→落缓冲区→可失败」的完整先例，JobRunner 的 UI 状态机以它为底子改造，不另起炉灶。

### 5.2 TranslationProcessor（内置翻译）

- 首选 **Apple Translation framework**（macOS 15+）：设备端、免费、无 key。已知风险：`TranslationSession` 需要 SwiftUI `translationTask` 视图上下文才能触发模型下载与会话创建，纯 AppKit/无窗口场景能否稳定驱动**需要先做 spike**（方案：设置窗内嵌一个隐藏的 NSHostingView 承载 session；spike 失败则翻译降级为「AI 处理器的一个预设 prompt」，UI 不变）。
- 语言检测用 `NLLanguageRecognizer`（NaturalLanguage，macOS 10.14+，无风险）。
- 配置面：目标语言（默认 中↔英 自动互译）、运行时机（手动点击；探索稿的「在 AI 之前自动跑」并入预设，v1 不做自动链）。
- `LSMinimumSystemVersion` 保持 13.0，翻译入口在 <15 的系统上隐藏（`#available` 门控）。

### 5.3 AIProcessor（内置 AI）

- OpenAI 兼容 `POST {base_url}/chat/completions`，`stream: true`，标准 SSE 解析（`data: {json}` / `data: [DONE]`）。
- 配置：base URL、model、API key、系统提示词模板（预置「润色」「改写」「翻译」三个模板，可自定义）。
- 凭据存储：**0600 文件** `~/Library/RimeBuffer/ai-credentials.json`，理由同 §4.1（探索稿写的「仅钥匙串」在 ad-hoc 签名现实下会重蹈 RemoteIdentity 已否决的方案；文档明示：Developer ID 落地后迁 Keychain）。
- 网络边界声明（写进设置页文案）：**整个输入法主动出站只有四处**——AI API、SSE 订阅、SSH 子进程、隔空传字局域网；前三者默认关闭，配置后才激活。
- 隐私红线：发给 AI 的只有 `inputSnapshot`（用户显式选中的块），永不附带输入历史、preedit、剪贴板或屏幕上下文。

---

## 6. 投递层（需求 6）

### 6.1 目标模型

| 目标 | 级别 | 默认 | 行为 |
|---|---|---|---|
| 当前输入框 | 主要 | 开，不可关 | `client.insertText`（现状） |
| 配对设备 | 次要 | **迁移期默认开**（见 6.5），可关 | 经现有加密通道发送，等 ack |

探索稿的 AirDrop 目标已砍（§0.1）。

### 6.2 DeliveryRouter

`Delivery.insert` 的一行 fire-and-forget 升级为：

```swift
@MainActor
func deliver(chunks: [Chunk], to targets: [DeliveryTarget]) -> DeliveryRecord
```

- 本地目标：insertText 后立即 `.inserted`（IMK 无回执，如实记录）。
- 远端目标：生成 `messageID`，发送后挂起等 ack（超时 5s → `.failed`，块保留在缓冲区并标红——修掉审计确认过的「flush 把存在 client 对象当送达成功、文本静默丢失」缺陷，本方案顺带兑现）。
- 投递记录环形保留最近 200 条，调试页可看。

### 6.3 Echo 防回环（改道后的必答题）

现状防回环靠「远端收字直通上屏、不进缓冲区」（`RimeBufferController.swift:1466` 注释明示）。收字改道缓冲区后，用户按 Enter 会走正常上屏路径，而该路径今天无条件镜像给远端——**原样落地就是死循环**。

解法就在 Origin 上，一条规则：**`DeliveryRouter` 对 `origin == .remotePeer(X)` 的块，永不投递回设备 X**。同设备其他块正常镜像。规则写在 Router 内部，不是开关。

### 6.4 远端协议 v2

`SealedMessage` 扩帧：`Kind` 枚举加 `.ack`；载荷加 `messageID: UUID`。配对握手加 `protocolVersion`。两端都是自有设备（用户自己的两台 Mac），**不做 v1 兼容模式**：版本不匹配时提示对端升级，拒绝降级通信（避免半新半旧的回环语义）。seq 防重放计数器保留原职，不与 messageID 混用。

### 6.5 行为变更告知（对现有使用习惯的两处打破）

1. **远端收字不再直接上屏**——改为进传入轨待决。这是需求 6「统一进同一套 UI」的直接推论，也是安全不变量的要求。
2. **镜像发送从隐式恒开变为投递目标开关**——迁移时若用户已启用隔空传字则默认保持开（最小惊讶），但从此可见、可关。

---

## 7. 安全模型

| 措施 | 机制 | 备注 |
|---|---|---|
| 密码框保护 | 监测 Carbon `IsSecureEventInputEnabled()`：激活期间发送/接受按钮禁用+锁标，捕获与投递整体短路 | macOS secure input 本身已让第三方 IME 收不到密码键入，此措施防的是「缓冲区里已有的内容被投进密码框」与边缘 app 未启用 secure input 的场景 |
| 切换应用时重置 | `didActivateApplicationNotification`（监听已存在）触发 `BufferCore.clear()`；设置开关，默认开 | 推翻 `BufferModel.swift:53` 「preserving N queued blocks」的旧倾向，作为显式设置让用户选 |
| 本地端口鉴权 | 仅绑 127.0.0.1 + Bearer token（0600 文件）+ 常数时间比较 | 无 token 401，不产生任何 UI 痕迹 |
| 来源门控 | §4.4 三档 + 默认询问 | |
| 网络出站清单 | AI / SSE / SSH / 隔空传字四处，前三者默认关 | 设置页明示，作为隐私承诺 |
| 日志脱敏 | `IMELog` 全面改为「事件+长度」，不记 text 本体；文件 0600 + 10MB 轮转 | 连带修掉审计确认的「rimebuffer.log 明文记录所有上屏文本」高危项，随 M0 出 |
| 隐私红线 | MCP 无读取工具（§4.2）；AI 只见显式选中内容（§5.3） | 写死，不做开关 |

---

## 8. 设置窗信息架构

5 页 → **8 页、两组**（回答探索稿悬而未决的「候选窗/维护去哪了」：不消失，归入「输入法」组）：

```
输入法                 工作台
├─ 输入（现状+并击间隔） ├─ 缓冲区   工作流开关、切换应用重置、面板行为
├─ 候选窗（现状）        ├─ 来源     MCP/HTTP/SSE/SSH/配对设备 各自的启停·信任等级·token 管理·配对管理(自「隔空传字」页迁入)
└─ 维护（现状）          ├─ 处理器   翻译配置、AI 配置(URL/model/key/模板)
                        └─ 投递     目标开关(当前输入框·配对设备)、投递记录
```

「隔空传字」页拆解：配对/信任管理 → 来源页；发送开关 → 投递页。「安全」不单设页——安全项就近放在其语义所属页（门控在来源、红线声明在处理器、重置在缓冲区），避免第 9 页。探索稿的「捕获策略表」退化为缓冲区页的两个开关（剪贴板行已砍、编码行本为事实、安全字段行是恒真机制）。

---

## 9. 迁移路径与分期

每期独立可发版、可回退（不动身份三元组，CI 冻结断言继续护航）。

| 里程碑 | 内容 | 依赖 | 粗估 |
|---|---|---|---|
| **M0 安全底线** | secure input 短路、切换应用重置开关、日志脱敏+轮转 | 无 | ~200 行，1 天 |
| **M1 领域改造** | Chunk+Origin 落地、InboundBus、传入轨 UI、Remote 入站改道+echo 规则+协议 v2、Marine 包装为 provider（kind 复活）、来源徽标 | M0 | ~1000 行 |
| **M2 网关** | LocalGateway(HTTP server)、MCP server+tools、HTTP push、token 体系、来源设置页 | M1 | ~1100 行 |
| **M3 处理器框架+翻译** | JobRunner、Processor 协议、处理胶囊/结果块 UI、TranslationProcessor（含 spike）、处理器设置页 | M1 | ~800 行 |
| **M4 AI** | AIProcessor(SSE)、凭据管理、提示词模板 | M3 | ~500 行 |
| **M5 投递路由** | DeliveryRouter、DeliveryRecord、ack、失败保留标红、投递设置页 | M1 | ~500 行 |
| **M6 收尾** | SSEClientProvider、SSHProvider、设置窗 IA 重排完成、BufferBar 视觉对齐 S0d7w | M2 | ~700 行 |

合计 ≈ 4800 行增改（全工程现有 8500 行）。顺序上 M2/M3/M5 在 M1 之后可并行。每期验收 = §1.2 对应用户故事 + smoke（InboundBus 门控、Origin 路由、协议 v2 帧、SSE 解析器都是纯逻辑，照 matrix-smoke 模式写进 CI）。

### 9.1 技术 spike（动工前先验证，各半天）

1. **Translation framework 无 SwiftUI 上下文可用性**（§5.2）——失败即降级 AI 预设，方案不阻塞。
2. **NWListener 手写 HTTP/1.1 + SSE 长连接**的稳定性（keep-alive、半关闭、背压）——失败即引入 SwiftNIO 作为第一个外部依赖。
3. **MCP streamable HTTP 与 Claude Code / Codex 的实际握手**——用最小 echo server 先通一遍，确认两家客户端的 transport 兼容细节。

---

## 10. 对探索稿 17 个悬置问题的裁决记录

| # | 问题 | 裁决 |
|---|---|---|
| 1 | MCP 是否 Marine 化名 | 否，真 MCP（需求 2）；Marine 走兼容 provider 至迁移完成 |
| 2 | echo loop | Origin 规则，§6.3 |
| 3 | 处理器时机 | 入缓冲区侧跑，不在投递路径（§3.2 规则 3） |
| 4 | AI 谁来调 | 输入法内置（需求 5 推翻此前"外包给本地智能体"的建议） |
| 5 | 钥匙串 | 0600 文件，Dev ID 后迁移（§4.1/§5.3） |
| 6 | 剪贴板捕获 | 砍（§0.1） |
| 7 | 安全字段/切换重置 | M0 先行 |
| 8 | 手动编辑分叉 | 不做，append-only 维持（§0.1） |
| 9 | 候选窗/维护页去向 | 保留，归「输入法」组（§8） |
| 10 | 隔空传字页去向 | 拆入 来源+投递（§8） |
| 11 | 无条件镜像 | 变 opt-in 目标，迁移默认开（§6.5） |
| 12 | 按住 1.2s 发送 | 保留（§1.1） |
| 13 | 清空按钮 | 保留，与停止并存（§1.1） |
| 14 | 紧凑面板两轨还是三轨 | 三层（用户需求 1 直接定论） |
| 15 | 「远端」语义 | 本方案中远端=配对设备（出入站同一对端）；「远端算力」概念废弃，算力即处理器 |
| 16 | 分期 | §9 |
| 17 | 路线图还是草稿 | 草稿；本文档为收敛后的路线图 |

## 11. 开放风险

- Translation spike 失败 → 翻译体验降级为走 AI（需 key），「内置翻译」的免配置卖点受损。
- 三层面板高度：传入轨常驻会推高面板 ~36pt，低分屏上贴近 caret 时可能遮挡——传入轨空时隐藏（§1.1）是主要缓解，需真机验证。
- MCP 规范演进快，streamable HTTP transport 细节可能随客户端版本变动——spike 3 锁版本，README 注明测试过的客户端版本。
- 协议 v2 不兼容旧版：两台 Mac 必须同步升级，发版说明需醒目。
