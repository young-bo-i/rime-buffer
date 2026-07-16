# Enter输入法 (ETInput) · 系统架构

版本：2026-07-16 · 权威全局架构文档
关系：本文档描述**整个系统**（既有输入核心 + 缓冲工作台）。`WORKBENCH-DESIGN.md` 是工作台的产品方案与决策记录；`ARCHITECTURE.md` 是 P1 时代的交接文档（已滞后，仅存档）。三者冲突时以本文档为准。

代码规模：约 10500 行（Swift + 一层 C++ librime 桥）。单进程、后台 agent（`LSUIElement`）。

---

## 0. 一句话

Enter输入法是一个 **macOS 中文输入法**（IMKit + 自包含 librime），并在其上叠加了一个**上屏前的文本工作台**：本地打字、外部来源（MCP / HTTP / SSE / SSH / 配对设备）、内置加工（翻译 / AI）三路文本汇入同一个缓冲区，经人工确认后投递到当前输入框或配对设备——共用同一套三层面板 UI。

---

## 1. 分层总览

```
                          ┌─────────────────────────────────────────────────────────┐
   外部世界                │                    ETInput 进程 (单进程)                   │
                          │                                                          │
 Claude Code / Codex ─MCP─┤─▶┌───────────┐                                           │
 curl / 脚本  ────HTTP────┤─▶│LocalGateway│─┐                                        │
 服务器推送   ────SSE─────┤◀─│(127.0.0.1)│ │   ┌──────────┐                          │
 远程主机     ────SSH─────┤◀─ SSHProvider ┼──▶│InboundBus│──待决──▶ 传入轨 / 收件箱UI  │
 配对 Mac  ─AES-GCM双向───┤◀▶ RemotePeer ──┘   │  (门控)   │           │接受           │
 Marine(兼容)────轮询─────┤─▶ MarineBridge─────┘└──────────┘           ▼               │
                          │                                    ┌────────────┐         │
   ══════════════════════ │  ═══ 加 工 ═══                      │ BufferModel│◀── Rime  │
 OpenAI 兼容 API ─SSE─────┤◀▶┌──────────┐   结果块回写           │  (chunks)  │    commit │
 Apple 翻译(本地)─────────┤◀▶│ JobRunner │──────────────────────▶└─────┬──────┘         │
                          │  │  (actor)  │◀── 选中块 + 处理器 ──────────┘ │ Enter/发送   │
                          │  └──────────┘                                ▼              │
                          │                                     ┌────────────────┐     │
                          │                                     │ DeliveryRouter │     │
                          │                                     │  + echo 防回环  │     │
                          │                                     └──┬──────────┬──┘     │
                          │                    当前输入框(主,默认)  │          │配对(次)  │
                          │  ◀───────────── insertText ───────────┘          └────────▶│─▶ 配对 Mac
                          └─────────────────────────────────────────────────────────┘
                                    │ 底座
                              ┌─────┴──────┐
                              │  librime   │  (dlopen，自带；Squirrel 为回退)
                              └────────────┘
```

四个横切层，文本从上（来源）流到下（投递），中间是缓冲区枢纽：

| 层 | 职责 | 关键模块 |
|---|---|---|
| **来源层** Sources | 把外部文字收进来，门控后产出待决条目 | InboundBus, LocalGateway, 各 Provider |
| **缓冲层** Buffer | 所有文本的暂存枢纽；块携带来源 | BufferModel, Origin |
| **加工层** Processors | 上屏前对块做翻译/AI 变换，结果回缓冲 | JobRunner, TranslationProcessor, AIProcessor（计划） |
| **投递层** Delivery | 把确认后的块送到目标；防回环、防误投 | DeliveryRouter, Delivery（唯一插入咽喉） |

下面是底座：**输入核心**（Rime 引擎 + IMKit 事件 + 候选窗），它既独立工作（普通打字），又是缓冲层的一个来源（Rime commit）。

---

## 2. 数据流：一段文字的一生

```
① 本地打字         ② 外部来源                 ③ 加工
   键盘事件           MCP/HTTP/SSE/SSH            用户选中块 → 翻译/AI
     │                   │                         │
     ▼                   ▼                         ▼
  RimeEngine          LocalGateway              JobRunner (actor)
  processKey          → InboundBus.submit        run(input) async
     │ commit            │ 门控                     │ 结果 = 新块(role=result)
     ▼                   ▼                         ▼
  ┌──────────────────────────────────────────────────────┐
  │            BufferModel  (blocks: [Block])             │  ← 枢纽：每个块带 Origin
  │   缓冲模式 OFF → 直接上屏；ON → 暂存为块，等确认        │
  └──────────────────────────────┬───────────────────────┘
                                 │ 用户 Enter / 发送
                                 ▼
                          DeliveryRouter
                    ┌──── echo 防回环：remotePeer 来源不回投原设备
                    ├──── secure input 激活 → 整体拒绝
                    ▼
                Delivery.insert  ──▶ 当前输入框 (client.insertText)
                    └──────────────▶ 配对 Mac (RemoteTypingService，可选目标)
```

关键不变量（安全叙事，恒真）：
1. **外部文字永不自动上屏**——先进传入轨待决（或按信任等级进缓冲），只有用户动作触发上屏。
2. **处理器结果永不直接上屏**——先回缓冲成结果块。
3. **secure input（密码框）激活时，投递整体禁用**。
4. **配对设备是唯一例外**：走「直通上屏」档（产品决策），收字直接上屏，不进缓冲。

---

## 3. 领域模型（核心类型）

```
Origin ──────── 文本从哪来。驱动三件事：UI 来源徽标 / echo 防回环 / 来源门控
  case rime                         本地打字（无徽标）
  case marine                       Marine 草稿（兼容期，将并入 mcp）
  case mcp(client)                  MCP 客户端（自报名，不可验，仅展示）
  case http(source) / sse(feed) / ssh(host)
  case remotePeer(deviceID)         配对 Mac
  [计划] case processor(kind, jobID) 翻译/AI 结果块

Block (BufferModel 内) ── 缓冲区的一个块
  id / text / origin / createdAt
  [计划] role: ordinary | result(jobID, delivered)

InboundItem (InboundBus 内) ── 传入轨上的待决条目
  id / origin / title? / text / streaming / state(pending|accepted|rejected)

[计划] TransformJob ── 一次处理器运行
  id / processor / inputSnapshot(冻结的输入快照) / sourceChunkIDs / state

[计划] DeliveryRecord ── 轻量投递账本
  messageID / target / status(inserted|acked|failed)
```

设计要点：
- **Origin 是这次工作台重构的第一等公民**。一个枚举同时解决徽标、防回环、门控三件事。
- **结果块就是 Block**（`role=result`），不另设 ArtifactStore——发送/删除/清空对它一视同仁，即「交互用同一套 UI」在数据层的落点。
- **inputSnapshot = 轻量版「Turn 冻结」**：任务启动时拷贝文本快照，之后用户继续打字不影响在途任务，不引入显式 Turn 实体。

---

## 4. 子系统详解

### 4.1 输入核心（底座）

```
键盘事件 ─▶ RimeBufferController (IMKInputController 子类)
             │  · flagsChanged 逐字节时序、F1–F12/grave 映射、Cmd 直通
             │  · 并击门控 (仅 my_combo)、raw passthrough 兜底
             ├─▶ RimeEngine ──▶ CRimeBridge (C++) ──dlopen──▶ librime.dylib
             │      每 controller 一个 session；引擎全局单例             (自带，Squirrel 回退)
             ├─▶ CompositionSession   marked text / preedit（只在本地）
             └─▶ CandidateWindow      共享 NSPanel（候选条 + 内嵌缓冲 + 矩阵翻页）
```

- **RimeEngine / CRimeBridge**：手写声明整个 `RimeApi` 结构体，`dlopen` 优先加载自带 librime，失败回退系统 Squirrel。首启 `start_maintenance` 自部署，自包含无需装 Squirrel。
- **CandidateWindow**：唯一的候选/缓冲展示面。跟随 caret 定位（`lastGoodRect` 兜底），`nonactivatingPanel` 永不成 key window。矩阵翻页（行/列双视口，越过 3 行上限翻到底）已完成。
- **ChordController + ChordSettings**：并击 release-replay；时长现在是 UI 可配置项（`ChordSettings`，默认 0.10s，UserDefaults + 通知）。
- **StatusMenu**：不建独立 NSStatusItem，命令挂在系统输入法菜单里（设置 / 收件箱 / 工作台预览 / 更新 / 部署 / 重装 / 重启）。

### 4.2 缓冲层

```
BufferModel (单例)
  blocks: [Block]          插入点 insertionIndex
  enabled                  缓冲模式开关 (UserDefaults)
  resetOnAppSwitch         切换应用清空 (默认开，M0)
  transient 三件套         异步产出→加载态→落缓冲→可失败（Marine/未来处理器复用）
  deliver: (text, origin)→Bool    ← 携带 origin，供投递层做 echo 判定
  append(text, origin)     每次进块记来源
  sendAll / sendNextBlock  Enter 长按/短按，唯一出口
```

- **枢纽地位**：Rime commit、外部来源接受、处理器结果，三路最终都进 `blocks`。
- **来源徽标**：非 rime 块在 BufferInlineView 里带彩色点（远端紫/agent 琥珀/网络蓝），rime 块保持干净。
- **演进方向**：BufferModel 渐进重构为 BufferCore（加 result 角色、Turn 冻结），不一次掀翻。

### 4.3 来源层

```
各 Provider ──▶ InboundBus.submit(origin, text, title) ──門控──▶
                     │
      trust(origin): │  trusted → 直接进缓冲 (Marine)
                     │  ask     → 进 pending 待决 (MCP/HTTP/SSE/SSH，默认)
                     │  blocked → 丢弃
                     ▼
              pending: [InboundItem]  ──▶ 收件箱/传入轨 UI ──接受──▶ BufferModel.append
                                                        └──拒绝──▶ 丢弃
              背压：pending 上限 50、单条 20000 字上限（防本机 DoS）
              流式：beginStream/appendStream/endStream（SSE/MCP 原位更新一个条目）
```

**LocalGateway**（回环 HTTP 服务器，M2 已建）：
- `NWListener` 手写 HTTP/1.1，**只绑 127.0.0.1**，端口默认 47700。
- 端点：`GET /v1/health`（免鉴权）、`POST /v1/inbound`（HTTP push）、`POST /mcp`（MCP streamable HTTP）。
- 鉴权：除 health 外全部要 `Bearer <token>`，常数时间比较。Token 存 `~/Library/RimeBuffer/gateway-token`（0600，不用 Keychain——ad-hoc 签名下会反复弹密码，沿用 RemoteIdentity 已论证的决策）。
- **MCP 工具（只给不看不发）**：`buffer_push` + `buffer_stream_{begin,append,end}`。刻意不提供读缓冲、读上下文、触发投递的工具——隐私边界写死。
- 已实测：真 Claude Code `✓ Connected`，curl HTTP push / MCP tools/call 均进 InboundBus。

**Provider 清单**：

| Provider | 形态 | 状态 |
|---|---|---|
| MCP（经 LocalGateway） | Claude Code / Codex 推草稿 | ✅ M2 |
| HTTP push（经 LocalGateway） | 脚本 POST | ✅ M2 |
| SSE 订阅 | 订阅外部事件流 | 计划 M6 |
| SSH | `/usr/bin/ssh` 子进程流式读 stdout；密钥全交 ssh-agent，输入法不碰；用 argv 数组防参数注入 | 计划 M6 |
| RemotePeer | 现有 X25519+AES-GCM 通道 | 现状=直通上屏档（不改道，产品决策） |
| Marine | 现有轮询，标 `.marine`，trusted 直进缓冲 | ✅ 兼容期，后并入 MCP |

### 4.4 加工层（计划 M3-M4）

```
用户在缓冲轨选中块 ─▶ JobRunner (actor) 建 TransformJob，inputSnapshot 冻结
                         │ 并发上限 1，排队
                         ▼
                    Processor.run(input, onPartial) async throws → String
                         ├── TranslationProcessor  Apple 翻译，设备端，无 key
                         └── AIProcessor           OpenAI 兼容，SSE 流式
                         │ onPartial 携带「全量已生成文本」，主线程原位更新结果块（不产生碎块）
                         │ 流式回写 ~30Hz 合并，避免整面板 reflow 洪泛
                         ▼
                    结果作为新块 role=result 回 BufferModel，默认「待发送」
```

- **翻译（spike 已验证）**：macOS 26 的 `TranslationSession(installedSource:target:)` **无需 SwiftUI**，在真 app runloop 里可无头运行。唯一前提：语言模型要先下载（`notInstalled` 时需一次性 UI——设置窗里放一个 SwiftUI translationTask 触发系统下载弹窗，这是全系统唯一用到 SwiftUI 的点）。
- **AI**：输入法内置出站客户端。凭据存 0600 文件（同 token 决策，Dev ID 后迁 Keychain）。给 AI 的只有用户显式选中的块，绝不附带历史/preedit/剪贴板。
- **通用 AI 端点**（产品新增需求）：自定义 URL + 模型 + 密钥的 OpenAI 兼容接入，属 AIProcessor 的配置，不算 MCP/agent。

### 4.5 投递层（计划 M5）

```
DeliveryRouter.deliver(chunks, targets)
  目标：① 当前输入框(主,手动,默认)  ② 配对设备(次,可选，opt-in)
  · echo 防回环：origin==remotePeer(X) 的块永不回投 X（规则已在 M1 就位）
  · secure input 激活 → 拒绝（M0 已在 Delivery.insert 唯一咽喉落地）
  · 本地 insertText 同步；远端等 ack（协议 v2），失败保留标红
  · DeliveryRecord 环形账本
```

- **Delivery.insert 是所有上屏路径的唯一咽喉**——直接 commit、缓冲发送、raw、单字、远端收字，全走它。M0 的密码框护栏就放在这一处，一处全覆盖。

---

## 5. UI 架构

### 5.1 三层面板（唯一交互面）

```
┌─────────────────────────────────────────┐  ← CandidateWindow 的根竖排 stack
│ ① 传入轨   ● 远端·MacBook Pro   (靠右)   │  外部来源（单个当前源名称，共用 chip 样式）
│ ② 缓冲轨   |shij 晚点 朋友        (右→左) │  缓冲块 + 活动预编辑 + 光标 + 处理状态
│ ③ 候选窗   1 时间 2 实践 3 事件 …          │  本地打字（现有样式，不动）
└─────────────────────────────────────────┘
   配色：RimeUI 现有深色主题，单一强调色，共用一套 chip 样式
```

- **实现载体**：现有 CandidateWindow 根 stack 往上加传入轨，BufferInlineView 升级为缓冲轨。不新开窗口，不改 NSPanel 行为。
- **评审硬约束（集成时必须守）**：异步事件**只改数据、绝不拉起面板**（否则切走后每条外部消息把面板弹到无关 app 上）；传入轨**可见时恒定高度**（否则打坏 caret 定位）；流式**30Hz 合并**渲染。
- **当前状态**：`WorkbenchBarView` 是独立视觉组件（可预览、可截图），**尚未接进实时候选窗**——这是延迟敏感的集成，单独一轮做。过渡期用**收件箱窗口**（InboundTrayWindow）承担接受/拒绝，让 MCP→缓冲全链路今天就能用。

### 5.2 设置窗（两组六页）

```
输入法组                    工作台组
├─ 输入（方案 + 并击间隔）    ├─ 缓冲区（缓冲开关 + 切app重置 + 安全说明）
├─ 候选窗（主题 + 尺寸）      ├─ 连接（配对设备 + 外部来源：MCP/HTTP/SSE/SSH）
└─ 维护（统计/热力图/更新）   └─ 处理器（翻译 + AI）
```

- 缓冲区页真实可用；连接/处理器页部分真实、部分带里程碑标签（诚实标"即将支持"）。
- 「连接」页合并了原「隔空传字」（配对/信任）+ 网关开关 + token 管理，一个对端一行内聚收发。

### 5.3 其它 UI
- **StatusMenu**：系统输入法菜单里的命令入口。
- **InboundTrayWindow**：外部来源收件箱（过渡态，将并入传入轨）。
- **KeyboardHeatmapView**：按键热力图（维护页）。
- **开发预览模式**：`settings-preview/render`、`panel-render`、`gateway-serve` 子命令，无头渲染/验证，不接进正式菜单。

---

## 6. 并发模型

现有代码的最硬约束：`BufferModel.deliver` 是**同步闭包**，而翻译/LLM 必然异步。三条规则拆解：

```
① UI 与 IMK 全部主线程       IMK 回调、NSPanel 渲染本来就在主线程，维持现状
② JobRunner 是 actor         每个 TransformJob 一个 Task；onPartial 经 MainActor 串行回写；
                             取消 = task.cancel() + provider 关连接；clear/退出缓冲需级联取消在途 job
③ 投递保持同步               处理器在「入缓冲区侧」跑（结果先落缓冲），投递时无异步依赖
                             ← 这就是「安全门控恒真」的架构化表达，也绕开同步 deliver 死结
```

- **Provider 侧**：LocalGateway 在独立 NW 队列，产出统一 `DispatchQueue.main.async` 进 InboundBus（主线程）。
- **IMKit 边界（Swift 并发注意）**：`IMKTextInput` 非 Sendable，client 引用永不离开主线程，跨进 actor 的只传值类型快照。

---

## 7. 安全与隐私模型

```
威胁模型：token/0600 只防「跨用户 + 网络」；同用户进程在信任域内（能读 0600、能走 Accessibility）
```

| 措施 | 机制 | 状态 |
|---|---|---|
| 密码框保护 | `IsSecureEventInputEnabled()` 在投递动作时刻同步查；命中拒发 | ✅ M0（Delivery 唯一咽喉） |
| 切换应用重置 | `didActivateApplicationNotification`，过滤自身 bundle（开设置页不自毁） | ✅ M0 |
| 日志脱敏 | 用户文本走 `IMELog.redact()` 只记长度；日志 0600；CI 断言禁 `'\(…)'` 明文 | ✅ M0 |
| 本地端口鉴权 | 只绑 127.0.0.1 + Bearer token（0600）+ 常数时间比较 + 严格解析上限 | ✅ M2 |
| 来源门控 | MCP 自报名不可验 → 恒走「询问」；三档信任 | ✅ M2 |
| echo 防回环 | remotePeer 来源不回投；规则在 Origin/Router 内部，不是开关 | ✅ 规则就位 |
| MCP 隐私边界 | 工具只给不看不发；无读缓冲/读上下文/触发投递工具 | ✅ 写死 |
| 网络出站清单 | AI / SSE / SSH / 隔空传字 / 更新检查；前三默认关，设置页明示 | 计划随各模块 |
| 处理器隐私红线 | 只发用户显式选中的块，不带历史/preedit/剪贴板 | 计划 M3-M4 |

**明确不做**（v1 边界）：剪贴板捕获、AirDrop 目标、Turn/Artifact 完整版本模型、投递撤回、手动编辑块。

---

## 8. 进程、生命周期、持久化

- **进程**：单进程后台 agent（`LSUIElement`，`.accessory`）。IMKServer 连接名必须与 Info.plist 一致。持进程生命周期。
- **身份三元组冻结**：bundle id `com.isaac.inputmethod.RimeBuffer` + mode `.Hans` + 目录 `ETInput.app`，CI 断言钉死字面值（防重复注册鬼影）。
- **持久化**：
  - UserDefaults：缓冲开关、并击时长、候选窗尺寸、网关开关/端口、来源信任、外观。
  - 0600 文件：gateway-token、remote 身份私钥、（计划）AI 凭据。
  - JSON：按键统计（按日）、Rime 用户配置（`~/Library/RimeBuffer`）。
  - 日志：`~/rimebuffer.log`（0600，脱敏）。
- **自更新**：UpdateManager 每小时查 GitHub Releases（这是隐私清单要计入的第 5 处出站）。
- **发布链**：build_install.sh（dev→~/Library）/ make-pkg.sh（pkg→/Library）/ CI（编译 + plist 断言 + 日志断言 + 7 个 smoke）/ release.yml（通用二进制）。签名为 ad-hoc（Dev ID 未申请，是钥匙串决策的根因）。

---

## 9. 模块地图（现有源码，约 10500 行）

```
Sources/CRimeBridge/            librime C API 桥（手写 RimeApi + dlopen）
Sources/RimeBuffer/
  main.swift                    IMK 引导、全局接线、dev 子命令、系统观察者
  RimeBufferController.swift    IMKInputController 子类，事件主路径（最大文件）
  RimeEngine.swift              librime 封装（session 生命周期）
  CompositionSession.swift      marked text / preedit
  CandidateWindow.swift         共享候选/缓冲 NSPanel + 矩阵翻页
  BufferInlineView.swift        内嵌缓冲 chips（+来源徽标）
  BufferModel.swift             缓冲枢纽（blocks / deliver / transient）
  Origin.swift                  来源溯源 + echo 守卫              [工作台新增]
  Delivery.swift                唯一上屏咽喉 + 密码框护栏
  ChordController.swift         并击 + ChordSettings
  RimeKey/RimeModels/InputSchemaCatalog   键映射/模型/方案目录
  RimeUI.swift                  配色/主题
  StatusMenu.swift              系统输入法菜单命令
  SettingsWindow.swift          设置窗（两组六页）
  WorkbenchBarView.swift        三层面板视觉组件              [工作台新增]
  KeyFrequencyStore/KeyboardHeatmapView   按键统计 + 热力图
  UpdateManager.swift           自更新
  MarineBridge.swift            Marine 轮询来源
  Log.swift                     IMELog + redact
  Remote/                       隔空传字（X25519+AES-GCM 双向 + 配对）
    RemoteTypingService / RemoteConfig / RemoteIdentity / RemoteProtocol
  Inbound/                      来源层                          [工作台新增]
    InboundBus.swift            汇聚 + 门控 + 背压 + 流式
    LocalGateway.swift          回环 HTTP/MCP 服务器
    GatewayToken.swift          0600 token
    InboundTrayWindow.swift     外部来源收件箱（过渡 UI）
  [计划] Processors/            JobRunner / Processor / TranslationProcessor / AIProcessor
  [计划] Delivery/DeliveryRouter 多目标投递 + 账本
```

**测试**：无 XCTest target；7 个编进二进制的 smoke 子命令（schema / buffer / stats / matrix / origin / inbound / remote），CI 全跑。纯逻辑（视口数学、echo 判定、门控、ECDH framing）都可 smoke，UI/IMK 靠真机 + 无头渲染验证。

---

## 10. 里程碑状态

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M0** 安全底线 | 密码框护栏 / 切app重置 / 日志脱敏 | ✅ 发布 0.4.4 |
| **M1-A** 来源溯源 | Origin / echo 守卫 / 来源徽标 / Marine 正名 | ✅ 发布 0.4.5 |
| **前端** | 设置两组六页 / 三层面板视觉 / 预览入口 | ✅ 发布 0.4.6 |
| **spike** | NWListener HTTP/SSE ✓ · MCP 真 Claude Code ✓ · Apple 翻译无头 ✓ | ✅ 全过 |
| **M2** 网关+MCP | LocalGateway / MCP tools / InboundBus / token / 收件箱 | ✅ 主干+收件箱（0.4.7），传入轨接候选窗待做 |
| **M3** 处理器+翻译 | JobRunner / Processor / TranslationProcessor / 处理胶囊 UI | 计划 |
| **M4** AI | AIProcessor（SSE） / 凭据 / 通用端点 / 提示词模板 | 计划 |
| **M5** 投递路由 | DeliveryRouter / 多目标 / ack / 账本 | 计划 |
| **M6** SSE/SSH + 收尾 | SSE/SSH provider / 传入轨接候选窗 / 视觉对齐 | 计划 |

**作废/推迟**（产品决策）：远端改道 + 协议 v2（配对走直通上屏）；剪贴板捕获；AirDrop。

---

## 11. 关键约束与已踩的坑（给未来的自己）

1. **身份三元组永不再改**——10 天换 5 代身份造成过 10+ 重复注册鬼影，CI 断言已钉死。
2. **Delivery.insert 是唯一上屏咽喉**——任何新上屏路径都必须走它，安全护栏才生效。
3. **NWListener 连接对象必须持有**——不持有会立刻释放，`weak self` 变 nil，连接静默失效（spike 抓到过）。
4. **异步事件不许拉面板**——传入轨接候选窗时的头号坑。
5. **同步 deliver 死结**——处理器必须在「入缓冲侧」跑，不在投递路径上跑。
6. **翻译需要一次性模型下载**——唯一用到 SwiftUI 的点，放设置窗真窗口里。
7. **钥匙串 vs ad-hoc 签名**——ad-hoc 下钥匙串每次重装弹密码，所有密钥用 0600 文件；拿 Dev ID 后再迁。
