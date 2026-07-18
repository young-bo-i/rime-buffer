# Enter输入法 · 缓冲工作台（Workbench）产品方案与架构设计

版本：v0.3 决策更新 · 2026-07-18
状态：长期路线图；缓冲窗口部分已实现
上游输入：`new-rime.pen` 七张探索稿（wBwdM/XKzFo/e9aJFL/FBS3A/rulod/BMbRV/S0d7w）+ 产品负责人 2026-07-16 口头需求收敛
关系：本文档记录工作台路线与历史裁决；`new-rime.pen` 是视觉参考；`ARCHITECTURE.md` 是 P1 时代交接文档。运行时事实与本文冲突时以 `SYSTEM-ARCHITECTURE.md` 为准。

> 2026-07-17 早期决策（已被下一条覆盖）：缓冲区从候选 panel 拆成独立工作台，曾采用内嵌候选投影、全文预览与发送后留块方案。
>
> **2026-07-18 简化工作台覆盖决策（当前）**：工作台折叠为 44pt 单行细条，主条严格为拖拽图标、展开箭头、缓冲块轨和右侧发送；向上展开到总高 78pt 后只保留无应用去向的状态、编辑、缓冲 `NSSwitch` 和关闭。只有拖拽图标可移动窗口；pin/移屏仍从设置或输入法菜单进入。手动眼睛遮蔽、历史/恢复、清空/撤销都从产品与模型移除。缓冲模式继续复用常规 `CandidateWindow`，普通/Shift+Return 与 Backspace 隔离和 2px 长按进度不变。成功发送的 block 立即从 live buffer 消失且不保留明文历史，失败和未发送 block 原位保留。本文后续若仍描述“候选投影 / 全文预览 / 已发送对号留块”，均视为历史方案。

---

## 0. 一句话定位

把 Enter输入法从「Rime 提交的暂存队列」升级为**上屏前的文本工作台**：当前本地打字、已接受的 MCP/HTTP 内容与 Marine 草稿可进入同一缓冲区，经人工确认后投递；SSE/SSH、翻译/AI 与工作台内传入轨是后续路线图。配对设备保留既有加密直通，是不进入工作台的明确例外。

产品负责人拍定的六条需求（本方案的边界即由此划定）：

1. 缓冲区模式新定义：**中间是缓冲区，下方是本地打字候选词区，上方是外部数据源**
2. 本地智能体用 **MCP** 把文字传给输入法
3. 输入法**内置翻译**
4. 输入法可通过 **SSE / SSH / HTTP** 从外部获取文字
5. 输入法**内置 AI 能力**
6. 设备间传字（隔空传字）保留；后续产品决策将其定为**加密直通例外**，不统一进工作台（见 §12.1）

### 0.1 明确不做（v1 边界）

| 砍掉 | 理由 |
|---|---|
| 剪贴板粘贴捕获 | 不在需求清单里；收益/风险比全套最差（输入法读用户从别处复制的内容），设计稿自己都标了警告色 |
| AirDrop 投递目标 | 不在需求清单里；延后 |
| Turn/Artifact 完整版本模型（revision/derivedFrom/分叉） | 探索稿里最贵的部分；v1 用「结果块」轻量替代，版本化留给需求被验证之后 |
| 投递撤回（revoke） | 依赖版本模型与协议大改；延后 |
| 无边界自由编辑面 / diff reconcile | 不恢复旧 TextView 的自动切块与差分；v1 只提供显式单块编辑，保留 id、来源和创建时间 |
| 「实时镜像」预设 | 探索稿自己标注"高级预设；默认关闭"；v1 由投递目标开关覆盖此语义 |

---

## 1. 产品定义

### 1.1 独立缓冲工作台（缓冲模式主交互面）

下图是三轨产品路线的历史结构参考；当前运行时折叠为 44pt 单行缓冲条，功能层向上展开后总高 78pt，候选使用条下方的常规候选窗，传入轨仍由独立收件箱承载。

```
┌────────────────────────────────────────────────┐
│ ① 传入轨  MCP·Claude ⋯ HTTP脚本  待接收 3         │  ← 外部数据源（后续嵌入）
├────────────────────────────────────────────────┤
│ ② 缓冲轨  [朋友][晚点][shij|] 翻译1.2s ⏹ ➤ ⤢    │  ← 缓冲区（升级）
├────────────────────────────────────────────────┤
│ ③ 候选区  1.时间 2.实践 3.事件 …                 │  ← 本地打字（现状保留）
└────────────────────────────────────────────────┘
```

实现载体：`BufferWindowController` 拥有独立 `nonactivatingPanel`。折叠态是 44pt 单行主条：拖拽图标 → 展开箭头 → `BufferInlineView` → 发送；向上工具层只有状态 → 编辑 → 缓冲 `NSSwitch` → 关闭，展开后总高 78pt。切换展开态时保持窗口底边不动，因此条下方候选锚点稳定；只有 22pt 拖拽图标可移动面板，窗口仍可调整宽度、关闭、固定到所有桌面/全屏空间，frame 与展开态持久化并在多屏变化后校正。圆角层使用固定日/夜缓冲 palette，不依赖 HUD 背景采样，内缩到透明窗口边距并按 backing scale 在路径内画 hairline。`CandidateWindow` 继续独占候选状态、视觉与翻页逻辑：普通模式锚定 caret，缓冲模式默认把同一个 panel 锚定在细条下方。

各层职责：

- **① 传入轨（后续）**：当前外部待决项仍在 `InboundTrayWindow` 接受/拒绝，异步来源不得自行拉起工作台。未来可作为工作台内固定高度区域加入。
- **② 缓冲轨（已实现基础）**：主条显示拖拽、展开、待发送块 chips、来源徽标、插入点、Enter 长按进度和右侧纸飞机；轻按 Enter 发送下一块，按住约 1.2 秒或点击纸飞机发送全部。成功发送后 block 从 live rail 消失且不保存历史；失败和未发送 block 保留。
- **③ 候选区（已实现常规面板复用）**：候选、preedit、矩阵/单字选择始终由同一个 `CandidateWindow` 呈现；缓冲模式只把锚点移到细条下方，任何点击仍必须携带当前 `FocusToken`，过期动作无效。
- **编辑与隐私（已实现）**：单块编辑使用独立 key window，输入法对自身编辑器绕过缓冲捕获；被动工作台不抢外部焦点。编辑窗跟随日/夜 palette，并在重开时进入当前 Space/指针屏幕；空缓冲点击编辑会显示明确提示。工作台没有手动遮蔽，保留 secure-input 自动遮蔽与会话锁定隐藏。

### 1.2 用户故事（验收场景）

1. **打字暂存**（现状不回归）：缓冲模式下打字 → 常规候选窗显示在细条下方 → commit 成块。有未决组字时，本次普通/Shift+Return 只收束为块；没有组字时轻按发送下一块、按住约 1.2 秒发送全部。Backspace 只编辑 Rime/缓冲；两个键在任何引擎/焦点状态下都绝不影响宿主文本框。焦点不可信时只吞不投递；引擎故障但没有未决组字时，已有块仍可发送。发送目标只认 Return keyDown 绑定且当前仍有效的精确焦点；成功块立即离开 live rail。
2. **智能体推稿**：Claude Code / Codex 通过 MCP 调 `buffer_push` → 当前由专用 toast/`InboundTrayWindow` 显示「MCP · <来源名>」待决项 → 用户点接受 → 成为带来源徽标的块 → 轻按 Enter 逐块发送，或长按/点击主条纸飞机发送全部到微信输入框。传入轨嵌入工作台是后续 UI 路线图。
3. **翻译**：选中/框选缓冲区里的块 → 点「翻译」→ 处理胶囊转圈计时 → 结果块出现（原块保留）→ 用户用 Enter 手势或主条纸飞机发送结果块。
4. **AI 润色**：同上，处理器换成 AI；SSE 流式期间**只更新同一个结果块**的文字，不产生逐 token 的碎块。
5. **隔空传字（收）**：配对 Mac 发来文字 → 沿既有加密直通路径上屏；若当前没有可用目标则累积到剪贴板。该产品例外不进入缓冲或传入轨（§12.1）。
6. **安全底线**：焦点在密码框（系统 secure input 生效）时，工作台遮蔽且发送被 `Delivery.insert` 拒绝，缓冲区任何内容不会被投递。当前收件箱的「接受」只把条目放进缓冲，因此不禁用也不显示锁标。

### 1.3 交互不变量（安全叙事，恒真，不做成开关）

- **非配对外部文字按当前固定门控进入收件箱或缓冲**：MCP/HTTP/SSE/SSH 为「询问」，Marine 为「信任」；无论哪一种都**永不**自动上屏。按来源自定义信任是后续能力；配对设备维持直通例外。
- **一切处理器结果先回缓冲区成为结果块**，绝不直接上屏。
- **缓冲内容、非配对外部文字与未来处理器结果只由用户明确触发上屏**：没有未决组字时，普通/Shift+Return 轻按发送下一块、按住约 1.2 秒发送全部；主条右侧纸飞机也可发送全部。有未决组字的 Return 只收束为块，同一物理按键绝不顺带投递。缓冲关闭时的普通 Rime commit，以及配对设备的既有直通收字，是明确例外。
- **secure input 激活时投递路径整体禁用**。

---

## 2. 领域模型

拆掉「Block 既是位置又是内容」的混合体，但只拆到 v1 需要的粒度：

```swift
/// 文字从哪来。既驱动 UI 徽标，也驱动 echo 防回环与门控。
enum Origin: Equatable, Codable {
    case rime                          // 本地打字（无徽标）
    case mcp(client: String)           // MCP 客户端自报名；不可验证，仅展示
    case http(source: String)
    case sse(feed: String)
    case ssh(host: String)
    case remotePeer(deviceID: String)  // 配对 Mac
    case marine                        // 兼容期；迁移完成后并入 .mcp
    case processor(kind: ProcessorKind, jobID: UUID)  // [M3 计划] 翻译/AI 结果块
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

/// 当前实现不定义 DeliveryRecord：IMK 接受 insertText 后，成功块立即从
/// live buffer 消费，不保留可恢复的明文发送快照。

// [M5 路线图，当前不存在]
// messageID / DeliveryTarget / inserted|acked|failed / 远端 ACK / 持久账本
```

设计要点：

- **`Origin` 是这次重构的第一等公民**。它同时解决三件事：UI 来源徽标、echo 防回环（§6.3）、来源门控（§4.4）。探索稿里 Marine `Draft.kind` 在入口被丢弃的 bug 由 `InboundItem.title` 承接。
- **结果块就是 Chunk**（`role: .result`），不另设 ArtifactStore。发送与显式删除对它一视同仁——这是「交互用同一套 UI」在数据层的对应物。
- **`inputSnapshot` 即轻量版「Turn 冻结」**：任务启动时拷贝文本快照，之后用户继续打字不影响在途任务。不引入显式 Turn 实体。

---

## 3. 总体架构

```
                       ┌────────────────────────────────────────────────┐
 外部世界               │                ETInput 进程                     │
                       │                                                │
 Claude/Codex ──MCP──▶ LocalGateway ─┐                                  │
 curl/脚本 ──HTTP────▶ (127.0.0.1)   ├─▶ InboundBus ─▶ 收件箱 UI         │
 [计划]服务器 ─SSE────▶ SSEProvider ──┤                    │ 接受         │
 [计划]远程主机 ─SSH──▶ SSHProvider ──┘                    ▼              │
 Marine(兼容期) ─轮询─▶ MarineBridge ───────────────▶ BufferModel         │
                       │                           │ Enter手势/主条纸飞机 │
                       │                                  ▼               │
                       │                       BufferDeliveryCoordinator  │
                       │                                  │               │
                       │                           Delivery.insert         │
                       │                                  ▼               │
                       │                              当前输入框            │
 配对Mac ◀─AES-GCM───▶ RemoteTypingService ─▶ 直通 Delivery.insert        │
                       │                     └─无目标→剪贴板累积            │
 [计划] OpenAI/翻译────▶ JobRunner ──结果块回写──▶ BufferModel             │
 [计划] 多目标/ACK─────▶ DeliveryRouter（M5；当前不存在）                   │
                       └────────────────────────────────────────────────┘
```

### 3.1 模块与文件规划

| 模块 | 新/改 | 文件 | 职责 |
|---|---|---|---|
| BufferModel | 已实现 | `BufferModel.swift` | live blocks、插入点、成功消费、transient 状态；不留发送历史 |
| InboundBus | 已实现 | `Inbound/InboundBus.swift` | 汇聚当前 MCP/HTTP，执行固定门控，产出 InboundItem |
| SourceProvider 协议 | [计划] | `Inbound/SourceProvider.swift` | 未来 provider 的 `start()/stop()`、事件回调、健康状态 |
| LocalGateway + MCP | 已实现 | `Inbound/LocalGateway.swift` | 本地 HTTP 服务器；stateless MCP POST + HTTP push + health |
| SSEClientProvider | [计划] | `Inbound/SSEClient.swift` | 订阅外部 SSE URL |
| SSHProvider | [计划] | `Inbound/SSHProvider.swift` | `/usr/bin/ssh` 子进程流式读取 |
| RemoteTypingService | 已实现、保持直通 | `Remote/RemoteTypingService.swift` | 配对设备加密直通；不进入 InboundBus |
| MarineBridge | 已实现、兼容期 | `MarineBridge.swift` | 当前可信草稿直接进 BufferModel；未来迁 MCP 后删除 |
| JobRunner | [计划 M3] | `Processors/JobRunner.swift` | actor；任务队列、进度、取消 |
| Processor 协议 | [计划 M3] | `Processors/Processor.swift` | `run(input, onPartial) async throws -> String` |
| TranslationProcessor | [计划 M3] | `Processors/TranslationProcessor.swift` | Apple Translation（macOS 15+，见 §5.2 风险） |
| AIProcessor | [计划 M4] | `Processors/AIProcessor.swift` | OpenAI 兼容 chat/completions，SSE 流式 |
| FocusCoordinator | 新（已实现） | `InputFocusCoordinator.swift` | FocusToken、client 租约、前台与对象身份校验 |
| BufferDeliveryCoordinator | 新（已实现） | `BufferDeliveryCoordinator.swift` | 逐块复核目标、成功块无历史消费、失败后缀保留 |
| DeliveryRouter | 后续 | `Delivery.swift` → `Delivery/DeliveryRouter.swift` | 多目标、远端 ACK、持久账本 |
| 独立工作台 | 新（已实现） | `BufferWindowController.swift` + `BufferInlineView.swift` | 44pt 简化主条、向上展开至 78pt、Switch/状态/编辑/多屏/安全遮蔽 |
| 候选状态机 | 改（已实现） | `CandidateWindow.swift` | 同一个常规 panel 锚定 caret 或缓冲条下方 |
| 设置窗 | 六页已实现，后续再拆 | `SettingsWindow.swift` | 当前 IA 见 §8；来源信任/投递页仍属路线图 |

### 3.2 并发模型（现有代码最硬的墙，正面拆）

现状：IMKit client 始终留在主线程；`BufferDeliveryCoordinator` 同步逐块投递，并在每块前复核 `FocusToken`、组字和 secure-input 状态。`BufferModel` 不再持有 deliver 闭包。

拆法（三条规则，不引入第四条）：

1. **UI 与 IMK 全部 `@MainActor`**。BufferCore、InboundBus 的对外表面是 main-actor 的——IMKit 回调、NSPanel 渲染本来就在主线程，维持现状最省事也最不容易错。
2. **JobRunner 是 `actor`**，每个 TransformJob 一个 `Task`。运行中通过 `onPartial` 回调把流式片段 `await MainActor.run` 回写结果块；结束/失败/取消同理。取消 = `task.cancel()` + provider 侧关闭连接。
3. **投递保持同步**。`insertText` 本来就是主线程同步调用；处理器在**入缓冲区侧**跑（结果块先落缓冲区），投递时不再有异步依赖。**处理器在缓冲区跑，不在投递路径上跑**；投递链只做实时目标校验和同步插入。

Provider 侧：当前 LocalGateway 持有独立 NW 队列并切回主线程调用 `InboundBus`；未来 SSE/SSH provider 也必须遵守同一边界。

---

## 4. 来源层（需求 2、4、6）

### 4.1 LocalGateway：当前 stateless MCP + HTTP push

当前一个监听器绑定 `127.0.0.1:47700`（可配置），基于 Network.framework `NWListener` 手写极简 HTTP/1.1。响应使用 `Content-Length` 并保持 keep-alive；**没有 chunked 响应、MCP SSE 下行流或可删除的 MCP session**。MCP 采用 stateless Streamable HTTP：每次 `POST /mcp` 返回一个 JSON 响应。SSE 订阅是后续独立 provider，不是当前 LocalGateway 的第三种协议。

除公开健康检查外，端点要求 `Authorization: Bearer <token>`。token 生成后写入 `~/Library/RimeBuffer/gateway-token`（0600，与 RemoteIdentity 的既有决策一致——**不用 Keychain**，因为 ad-hoc 签名下 Keychain ACL 每次重装都会弹窗；拿到 Developer ID 正式签名后再评估迁移）。当前设置页可复制 token、MCP 配置和 curl 命令，但**没有重新生成 token 的 UI**。

端点：

```
POST /mcp                    MCP streamable HTTP（初始化/工具调用/通知）
POST /v1/inbound             裸 HTTP push：{text, title?, source?}
GET  /v1/health              健康检查（无鉴权，当前返回 {"ok":true}）
GET/DELETE /mcp              当前明确返回 405，Allow: POST
```

### 4.2 MCP tools（面向 Claude Code / Codex 等本地智能体）

```
buffer_push(text, title?)               → 确认文本      推一条待决条目到收件箱
buffer_stream_begin(title?)             → {stream_id} 开一个流式条目（占位卡片）
buffer_stream_append(stream_id, delta)  → 确认文本      原位追加文字（不产生新条目）
buffer_stream_end(stream_id)            → 确认文本      标记完成，条目变为可接受
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
| **SSEClientProvider** | [计划] 主动订阅用户配置的 URL 列表；流式进入 InboundBus | 当前只有设置页未来标签，尚无实现 |
| **SSHProvider** | [计划] `Process` 跑 `/usr/bin/ssh <host> <command>`，stdout 流式进条目 | 当前只有设置页未来标签；未来认证依赖用户 `~/.ssh` 与 ssh-agent |
| **RemoteTypingService** | 现有 X25519+AES-GCM 通道，入站继续直接 `insertRemoteText` | 不进 InboundBus；无安全目标时由 main.swift 累积到剪贴板；协议 v2 推迟 |
| **MarineBridge** | 现有轮询，按固定 trusted 规则直接进入 BufferModel | 迁移期方案；Marine 改用 MCP push 后删除兼容握手 |

### 4.4 来源门控（传入轨的准入策略）

`SourceTrust` 类型包含三档，但**当前没有按来源配置或 UserDefaults 覆盖**。`InboundBus.trust(for:)` 的固定规则是：Marine=`trusted`；MCP/HTTP/SSE/SSH=`ask`；Rime/RemotePeer 若误入总线也按 `ask` 处理。

| 等级 | 行为 |
|---|---|
| **询问**（默认） | 条目进传入轨待决，用户逐条接受/拒绝 |
| **信任** | 条目直接进缓冲区成为块（仍绝不自动上屏，§1.3 不变量兜底） |
| **拦截** | 丢弃；当前没有设置入口，也没有“计数器闪一下”的 UI |

无有效 token 的请求在 HTTP 层直接 401，不进任何 UI。MCP 客户端名只存在于当前连接内，是未经验证的自报展示名；它不与全局 token 建立身份绑定。

**[后续路线图]** 若加入来源设置页，再把三档选择持久化到 UserDefaults，并为 blocked 提示设计明确 UI；在此之前不得把它们写成现有保证。

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
- 网络边界声明（写进设置页文案）：**整个输入法主动出站共五类**——AI API、SSE 订阅、SSH 子进程、隔空传字局域网、GitHub 自动更新检查。前三类尚属路线图且默认关闭；隔空传字按用户配对启用，更新检查当前每小时运行。
- 隐私红线：发给 AI 的只有 `inputSnapshot`（用户显式选中的块），永不附带输入历史、preedit、剪贴板或屏幕上下文。

---

## 6. 投递层（需求 6）

### 6.1 目标模型

| 目标 | 级别 | 默认 | 行为 |
|---|---|---|---|
| 当前实时输入框 | 主要 | 开，不可关 | 只有当前 FocusToken 租约通过对象身份、bundle 与前台 app 校验后才 `insertText` |
| 配对设备镜像 | 既有独立通路 | 用户既有设置 | 经现有加密通道发送；`.remotePeer` 来源不镜像回原设备 |

探索稿的 AirDrop 目标已砍（§0.1）。

### 6.2 当前本地投递基线与后续 Router

- 当前本地投递由 `BufferDeliveryCoordinator` 负责：每块发送前重验同一 token；焦点变化立即停止。
- `Delivery.insert` 调用成功只表示 IMKit 接受调用，不是宿主 ACK；当前产品在成功返回后立即把该 block 从 live buffer 消费，且不保留明文历史。局部失败立即停止，失败 block 和尚未发送后缀原位保留。
- 工作台不提供历史恢复或清空撤销。跨 app 隐私清理仍是不可恢复的安全操作。
- 多目标、远端 ACK、失败状态与持久账本仍属于后续 M5，不把未来能力写成当前保证。

### 6.3 Echo 防回环

配对收字维持直通，不进入缓冲；若已有 `.remotePeer` 来源块通过兼容路径进入缓冲，`origin.allowsRemoteMirror` 仍保证它不会回镜。输入法自身设置页与块编辑器也永不参与远端镜像。

### 6.4 远端协议 v2（推迟）

当前配对直通协议不因缓冲窗口改造而升级。messageID/ACK 只在未来多目标投递确有需求时另行设计。

### 6.5 当前行为

1. 配对设备收字继续直通；当前没有安全目标或投递被拒绝时，不报告假成功。
2. 缓冲工作台发送只认当前实时外部文本框；不会使用 recent/last client 兜底。

---

## 7. 安全模型

| 措施 | 机制 | 备注 |
|---|---|---|
| 密码框保护 | `Delivery.insert` 在投递时同步检查 `IsSecureEventInputEnabled()` 并拒发；工作台遮蔽。当前收件箱「接受」只暂存到缓冲，不禁用也无锁标 | macOS secure input 本身已让第三方 IME 收不到密码键入；核心保证是已有缓冲内容不能被投进密码框 |
| 切换应用时重置 | 显式设置，默认关；开启后仅当缓冲中没有任何外部来源块时不可撤销地丢弃 live blocks 并收束瞬态状态 | 常驻工作台默认跨 app 保留；外部待投递内容绝不因切目标而自动丢弃 |
| 焦点与自有窗口 | FocusToken 精确租约；自有设置/编辑文本框既不进缓冲，也不远端镜像 | 迟到 deactivate/command/candidate click 不能影响新目标 |
| 本地端口鉴权 | 仅绑 127.0.0.1 + Bearer token（0600 文件）+ 常数时间比较 | 无 token 401，不产生任何 UI 痕迹 |
| 来源门控 | §4.4 三档类型 + 当前硬编码规则；无按来源设置 | 可配置覆盖属后续路线图 |
| 网络出站清单 | AI / SSE / SSH / 隔空传字 / GitHub 更新检查五类 | 前三属路线图且默认关；后两按现有设置运行 |
| 日志脱敏 | `IMELog` 全面改为「事件+长度」，不记 text 本体；文件 0600 + 10MB 轮转 | 连带修掉审计确认的「rimebuffer.log 明文记录所有上屏文本」高危项，随 M0 出 |
| 隐私红线 | MCP 无读取工具（§4.2）；AI 只见显式选中内容（§5.3） | 写死，不做开关 |

---

## 8. 设置窗信息架构

当前实现是 **6 页、两组**：

```
输入法                 工作台
├─ 输入（现状+并击间隔） ├─ 缓冲区   捕获、窗口显隐/pin、候选锚点、移屏、切app清理
├─ 候选窗（现状）        ├─ 连接     配对设备、网关启停/端口/配置复制；SSE/SSH 未来标签
└─ 维护（现状）          └─ 处理器   当前为未来能力说明
```

缓冲页明确展示：关闭窗口会收束组字、暂停捕获、结束未完成的瞬态状态并保留已有块。候选默认使用常规面板锚定在细条下方，可切回跟随 caret；菜单也提供显隐、pin 与移到当前屏幕。「安全」不单设页，安全项就近放在语义所属页。

**[后续路线图]** 等按来源信任和多目标投递真正实现后，可把「连接」拆成独立「来源」与「投递」页，形成原方案中的 8 页 IA；当前不得把该拆分写成已完成。

---

## 9. 迁移路径与分期

每期独立可发版、可回退（不动身份三元组，CI 冻结断言继续护航）。下表已按当前决策重写；完成状态以 §12.2 为准，未实现项保留为路线图。

| 里程碑 | 内容 | 依赖 | 状态 / 原粗估 |
|---|---|---|---|
| **M0 安全底线** | secure input 短路、切换应用重置开关、日志脱敏 | 无 | ✅ 已完成 |
| **M1 领域改造** | Origin、来源徽标与 echo 守卫已落地；工作台内传入轨后续；Remote 入站改道/协议 v2 已取消或推迟 | M0 | 部分完成 |
| **M2 网关** | LocalGateway、stateless MCP tools、HTTP push、token 与收件箱已完成；按来源信任设置尚未实现 | M1 | ✅ 主干完成 |
| **M3 处理器框架+翻译** | JobRunner、Processor 协议、处理胶囊/结果块 UI、TranslationProcessor（含 spike）、处理器设置页 | M1 | ~800 行 |
| **M4 AI** | AIProcessor(SSE)、凭据管理、提示词模板 | M3 | ~500 行 |
| **M5 投递路由** | [计划] DeliveryRouter、多目标、远端 ack、失败状态与持久账本；当前仅有本地精确焦点投递且不保存发送历史 | M1 | ~500 行 |
| **M6 收尾** | [计划] SSEClientProvider、SSHProvider、工作台内传入轨、设置窗 IA 再拆分与视觉对齐 | M2 | ~700 行 |

原始未实现部分曾粗估约 4800 行；工程当前约 14000 行，该估算不再代表剩余工作量。后续每期验收仍对应 §1.2 用户故事，并为新增纯逻辑补 smoke；协议 v2 已推迟，不属于当前 CI 契约。

### 9.1 历史技术 spike（已完成，不等于下列产品能力均已实现）

1. **Translation framework 无 SwiftUI 上下文可用性**（§5.2）——可行性 spike 已通过；产品级模型下载与 Processor 仍未实现。
2. **NWListener 手写 HTTP/1.1 + SSE 长连接**的稳定性——spike 已通过；当前产品只落地 stateless MCP/HTTP 子集，SSE client 仍属 M6。
3. **MCP streamable HTTP 与 Claude Code / Codex 的实际握手**——最小握手已通过；当前正式契约以 §4.1 的 stateless POST 实现为准。

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
| 8 | 手动编辑分叉 | 不做无边界自由编辑与自动 diff/reconcile；允许显式单块编辑并保留 id/origin/createdAt |
| 9 | 候选窗/维护页去向 | 保留，归「输入法」组（§8） |
| 10 | 隔空传字页去向 | [路线图] 来源/投递能力成熟后再拆页；当前仍在「连接」页（§8） |
| 11 | 无条件镜像 | v1 保持既有隔空传字设置；自身窗口永不镜像，`.remotePeer` 来源永不回镜（§6.3） |
| 12 | 按住 1.2s 发送 | 已实现；无未决组字时轻按发下一块、按住约 1.2 秒发全部。有未决组字时本次按键只收束，不发送（§1.1） |
| 13 | 清空按钮 | 2026-07-18 覆盖裁决：移除按钮、清空与撤销功能；只保留不可恢复的自动安全清理 |
| 14 | 紧凑面板两轨还是三轨 | 三层仍是历史路线目标；当前运行时采用 44pt 单行缓冲条 + 向上工具层（总高 78pt）+ 条下方常规候选窗，传入轨仍待嵌入 |
| 15 | 「远端」语义 | 本方案中远端=配对设备（出入站同一对端）；「远端算力」概念废弃，算力即处理器 |
| 16 | 分期 | §9 |
| 17 | 路线图还是草稿 | 草稿；本文档为收敛后的路线图 |

## 11. 开放风险

- Translation 可行性 spike 已通过，但模型下载、系统版本门控与 AppKit/SwiftUI 生命周期尚未集成到产品 Processor，仍需真机验证。
- 焦点竞态：同一 app 多文本框可能复用 IMK client proxy；必须依靠每次 activation 新 epoch、事件顺序与迟到 callback 拒绝，真机覆盖 Safari/Electron/微信。
- 常显隐私：工作台跨桌面/全屏可见，必须保持 secure-input 低频检测、自动隐私清理与锁屏隐藏；产品不再提供手动遮蔽状态。
- 编辑器激活会主动让旧外部目标失效；保存后必须回到目标 app 并重新取得焦点，不能偷偷复用旧租约。
- MCP 规范演进快，streamable HTTP transport 细节可能随客户端版本变动——spike 3 锁版本，README 注明测试过的客户端版本。
- [未来条件风险] 若 M5 重新启动配对协议 v2/ACK 设计，必须先确定版本协商与兼容策略；当前版本未实现 v2，也不要求两台 Mac 同步升级。

---

## 12. 实施进度与决策更新

### 12.1 产品负责人已拍板的决策（覆盖 §10 的对应条目）

- **隔空传字 = 「直通上屏」档**（覆盖 §10 #10/#15 的早期设想）：配对设备收到的文字**直接上屏**，保留现状的无人值守实时传字。它**不进传入轨、不进缓冲区**。因此原 §6.5「远端收字改道缓冲区」与「协议 v2」在 v1 **作废/推迟**——没有改道就不存在缓冲内 echo 死循环，也不需要 ack 账本。§1.3 的「外部文字先待确认」不变量只对**非配对来源**（MCP/HTTP，以及未来 SSE/SSH）生效。
- **起步 = M0 安全底线**（已完成，见下）。

### 12.2 里程碑实际状态

- **M0 安全底线** — ✅ 已发 v0.4.4：secure-input 护栏（Delivery.insert 唯一咽喉）、可选切换应用清理、日志脱敏（IMELog.redact + 0600 + CI 断言）。当前常驻工作台默认不清理。
- **M1 领域改造** — 部分完成：
  - ✅ **M1-A 来源溯源 + echo 规则**：`Origin.swift` 枚举、`Block.origin`、`Origin.allowsRemoteMirror` echo 守卫（远端来源不回镜）、`origin-smoke`（已入 CI）。Marine 草稿标记 `.marine`。
  - ✅ **来源徽标**：BufferInlineView 给非 rime 块画彩色点（远端紫/agent 琥珀/网络蓝），rime 块保持无徽标。
  - ⏸ **传入轨 UI**：M2 网关前置条件已经满足；当前仍使用 `InboundToast` + `InboundTrayWindow`，嵌入独立工作台的传入轨尚未实现。配对设备继续直通不入轨，Marine 现状直接进 buffer。
  - ⏹ **远端改道 + 协议 v2**：按 §12.1 决策**作废**。
- **M2 网关+MCP** — ✅ 主干已实现：`LocalGateway`、MCP tools、`InboundBus`、token 与收件箱可用；传入轨嵌入工作台仍后续。
- **稳定缓冲窗口** — ✅ 2026-07-18：FocusToken、Return 轻按逐块/长按全部手势、Return/Backspace 宿主隔离、44pt 简化主条/78pt 向上功能层、条下方常规候选窗、成功块无历史消费、块编辑防回灌、多屏/常显与 secure-input 保护已实现；待重新安装后的真实宿主输入交互验收。

### 12.3 下一步真实工作量

M2 已能向收件箱与 BufferModel 喂真实数据；下一步若继续三层工作台路线，可直接把 `InboundBus.pending` 投影为工作台内固定高度的传入轨。异步事件不得自动拉起候选面板或工作台，但当前允许专用 nonactivating toast/收件箱提示。处理器与多目标/远端 ACK 仍按 M3–M5 独立推进。
