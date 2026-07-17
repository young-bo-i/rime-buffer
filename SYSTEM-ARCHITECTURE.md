# Enter输入法 (ETInput) · 系统架构

版本：2026-07-17 · 权威全局架构文档
关系：本文档描述**整个系统**（既有输入核心 + 缓冲工作台）。`WORKBENCH-DESIGN.md` 是工作台的产品方案与决策记录；`ARCHITECTURE.md` 是 P1 时代的交接文档（已滞后，仅存档）。三者冲突时以本文档为准。

代码规模：约 14000 行（Swift + 一层 C++ librime 桥）。单进程、后台 agent（`LSUIElement`）。

---

## 0. 一句话

Enter输入法是一个 **macOS 中文输入法**（IMKit + 自包含 librime），并在其上叠加了一个**独立、常驻、上屏前的文本工作台**：本地打字与已接受的外部文字汇入同一个缓冲区，经人工确认后投递到一个经过实时焦点校验的输入框。工作台折叠为 44pt 单行细条，全部功能向上展开后总高 78pt；底边与候选锚点不随展开移动。候选与 preedit 继续由常规 `CandidateWindow` 呈现，缓冲模式下默认锚定在细条下方。

---

## 1. 分层总览

```
                          ┌──────────────────────────────────────────────────────────┐
   外部世界                │                    ETInput 进程（单进程）                    │
                          │                                                           │
 Claude Code / Codex ─MCP─┤─▶ LocalGateway ─┐                                         │
 curl / 脚本  ────HTTP────┤─▶ (127.0.0.1)   ├─▶ InboundBus ─待决─▶ InboundTrayWindow  │
 [计划]服务器推送 ─SSE─────┤─▶ SSEProvider ──┤                         │ 接受            │
 [计划]远程主机 ───SSH─────┤─▶ SSHProvider ──┘                         ▼                 │
 Marine(兼容)────轮询─────┤─▶ MarineBridge ───────────────────▶ BufferModel ◀─ Rime   │
                          │                                      (blocks)     commit  │
                          │                                Return 手势 / 显式纸飞机       │
                          │                                         ▼                  │
                          │                              BufferDeliveryCoordinator     │
                          │                                         │                  │
                          │                                  Delivery.insert           │
                          │                                         ▼                  │
                          │                                    当前输入框               │
                          │                                                           │
 配对 Mac  ─AES-GCM双向───┤─▶ RemoteTypingService ─▶ insertRemoteText ─▶ Delivery.insert│
                          │                                  └─无安全目标→剪贴板累积    │
                          │                                                           │
 [计划] OpenAI/Apple 翻译──┤◀▶ JobRunner ──结果块回写──▶ BufferModel                    │
 [计划] 多目标/远端 ACK────┤◀▶ DeliveryRouter（M5；当前不存在）                          │
                          └──────────────────────────────────────────────────────────┘
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
| **投递层** Delivery | 把确认后的块送到目标；防过期焦点、防回环、防误投 | InputFocusCoordinator, BufferDeliveryCoordinator, Delivery（唯一插入咽喉） |

下面是底座：**输入核心**（Rime 引擎 + IMKit 事件 + 候选窗），它既独立工作（普通打字），又是缓冲层的一个来源（Rime commit）。

---

## 2. 数据流：一段文字的一生

```
① 本地打字         ② 外部来源                    ③ [计划] 加工
   键盘事件           MCP/HTTP；[计划] SSE/SSH       用户选中块 → 翻译/AI
     │                   │                         │
     ▼                   ▼                         ▼
  RimeEngine          LocalGateway              [计划] JobRunner (actor)
  processKey          → InboundBus.submit        run(input) async
     │ commit            │ 门控                     │ 结果 = 新块(role=result)
     ▼                   ▼                         ▼
  ┌──────────────────────────────────────────────────────┐
  │            BufferModel  (blocks: [Block])             │  ← 枢纽：每个块带 Origin
  │   缓冲模式 OFF → 直接上屏；ON → 暂存为块，等确认        │
  └──────────────────────────────┬───────────────────────┘
                                 │ Return 轻按/长按或点击展开层纸飞机
                                 ▼
                     BufferDeliveryCoordinator
                    ┌──── FocusToken/controller/client 身份、bundle 与前台 bundle/PID 精确匹配
                    ├──── 组字未决 / secure input → 拒绝或先显式收束
                    ├──── 每个块投递前再次校验，焦点变化立即停
                    ▼
                Delivery.insert  ──▶ 当前输入框 (client.insertText)
```

关键不变量（安全叙事，恒真）：
1. **非配对外部文字永不自动上屏**——MCP/HTTP 先进收件箱待决；Marine 按当前固定信任规则进缓冲，但仍只有用户动作触发上屏。
2. **处理器结果永不直接上屏**——先回缓冲成结果块。
3. **secure input（密码框）激活时，投递整体禁用**。
4. **缓冲投递不保存“最近输入框”兜底**：只有当前 `FocusToken` 的外部文本框能接收，且租约记录的 bundle 与进程 PID 必须同时匹配当前前台应用；切 app、切文本框、同 bundle 应用重启或打开块编辑器都会令旧目标失效。
5. **手动投递不等于目标已确认收到**：当前产品在 `Delivery.insert` 成功返回后立即消费 live block，并把快照写进最多 50 条进程内历史；失败的块和后续尚未发送的块原位保留，历史恢复必须由用户显式触发。
6. **配对设备是来源侧唯一直通例外**：收到的文字沿既有实时传字路径直接上屏，不进入缓冲工作台。
7. **缓冲按键与宿主隔离**：缓冲模式下普通/Shift+Return 与 Backspace 总是被输入法消费。有未决 Rime/并击/raw 输入时，本次 Return 只收束成缓冲块并抑制同一物理按键余下事件；没有未决组字时，轻按发送下一块，按住约 1.2 秒发送全部。Backspace 只在精确焦点下编辑 Rime/并击状态或删除缓冲块。焦点不可信时始终吞键且不投递；引擎故障时，无法安全收束的未决组字只吞不发，但无未决组字的已有块仍可发送。宿主绝不会收到换行或删除。

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

Block (BufferModel 内) ── 缓冲区的一个块；live blocks 均为待发送
  id / text / origin / createdAt / lastSentAt? / lastSentTargetBundleID?
  [计划] role: ordinary | result(jobID, delivered)

InboundItem (InboundBus 内) ── 传入轨上的待决条目
  id / origin / title? / text / streaming / state(pending|accepted|rejected)

[计划] TransformJob ── 一次处理器运行
  id / processor / inputSnapshot(冻结的输入快照) / sourceChunkIDs / state

DeliveryRecord ── 当前进程内的轻量投递历史（最多 50 条）
  id / blocks(snapshot) / originalOrder / targetBundleID / targetName / sentAt
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
             ├─▶ InputFocusCoordinator  FocusToken + client 身份 + 前台 bundle/PID 租约
             └─▶ CandidateWindow      唯一候选面板；锚定 caret 或缓冲条下方
```

- **RimeEngine / CRimeBridge**：手写声明整个 `RimeApi` 结构体，`dlopen` 优先加载自带 librime，失败回退系统 Squirrel。首启 `start_maintenance` 自部署，自包含无需装 Squirrel。
- **RimeBufferController 按键隔离与 Enter 手势**：缓冲模式在最外层吞掉普通/Shift+Return 与 Backspace。Return keyDown 绑定当时的 `FocusToken`；有未决组字时只收束并抑制到物理抬起，否则 keyUp 或物理轮询检测到抬起时请求 `sendNext`，持续物理按住到 1.2 秒时请求 `sendAll`。发送动作与 callback ownership 独立：每次被接管的物理按键持有 sticky keyUp / `didCommand(insertNewline:)` suppression，发送最后一个 transient block 令 buffer inactive、动作 reset 或失焦都不能把迟到/重复回调放给宿主；旧字段的 stale callback 不改变当前按压状态，下一次确认的 non-repeat keyDown 才退休旧代并立即按新状态路由。`handle(_:client:)` 是 Return 唯一动作入口，`didCommand` 仅防御性吞命令，不形成第二条发送路径。Backspace 仅在精确租约下改 Rime/缓冲。隔离分支先于 raw fallback，故引擎失败和不可信焦点也不会把这两个键交给宿主。
- **CandidateWindow**：候选交互与显示的唯一状态机。普通模式锚定 caret；缓冲模式默认把同一个 `nonactivatingPanel` 锚定在缓冲条下方，因此主题、尺寸、翻页、单字选择和 token 化点击行为与常规候选完全一致。工作台不再维护 `CandidateProjection` 或第二份候选视图。
- **InputFocusCoordinator**：把 controller、租约 `IMKTextInput`、`controller.client()` 当前对象身份、bundle id、前台应用 PID 与单调 token 绑定；`liveTarget` 同时重验全部身份与前台 PID，防止同 bundle 应用重启或文本框切换后复用旧租约。事件时间戳必须晚于 activation floor/最近已接受事件；先于 activate 的首键只建立短期 provisional 租约。explicit/implicit lifecycle callback 都必须与当前 client 一致；同一 proxy 跨字段或跨 controller 复用、异步 chord 回放失配、弱 client 过期时，旧 session 只在 Rime 内回收/丢弃，不调用已移动或释放的 proxy。
- **ChordController + ChordSettings**：并击 release-replay；时长现在是 UI 可配置项（`ChordSettings`，默认 0.10s，UserDefaults + 通知）。
- **StatusMenu**：不建独立 NSStatusItem，命令挂在系统输入法菜单里（设置 / 收件箱 / 显示或关闭工作台 / 常显 / 移到当前屏幕 / 更新 / 部署 / 重装 / 重启）。

### 4.2 缓冲层

```
BufferModel (单例)
  blocks: [Block]          插入点 insertionIndex
  enabled                  缓冲模式开关 (UserDefaults)
  resetOnAppSwitch         切换应用清空（显式隐私选项，默认关）
  transient 三件套         异步产出→加载态→落缓冲→可失败（Marine/未来处理器复用）
  append(text, origin)     每次进块记来源
  update/remove/clear      显式块编辑、删除与清空；身份和来源不变
  sentHistory              最近 50 次进程内发送快照；可显式恢复为待发送

BufferDeliveryCoordinator (单例)
  availability             当前精确目标 / 组字 / secure input / 待发送状态
  sendNext / sendAll       由 Return 手势或展开层纸飞机触发；每块重验 FocusToken、client 身份、前台 bundle/PID，经 Delivery.insert 投递
```

- **枢纽地位**：Rime commit、外部来源接受、处理器结果，三路最终都进 `blocks`。
- **来源徽标**：非 rime 块在 BufferInlineView 里带彩色点（远端紫/agent 琥珀/网络蓝），rime 块保持干净。
- **消费语义**：`Delivery.insert` 成功返回后，成功块会原子地进入 `sentHistory` 并从 live `blocks` 删除；失败时立即停止，失败块和未发送后缀保持原顺序。历史快照保留 `originalOrder`，显式恢复时能回到仍存活块之间的原相对位置。
- **编辑语义**：编辑器是独立 key window；进入时旧外部焦点租约失效，输入法对自身编辑器绕过缓冲捕获。保存只改目标块的文字并重新标记待发送，不改变 id、origin、createdAt。

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

### 4.5 投递层

```
InputFocusCoordinator.liveTarget(expected: token)
  · controller + client 对象身份 + bundle id + 前台 app 四重一致
  · 自身设置/编辑器不是外部投递目标
                         │
                         ▼
BufferDeliveryCoordinator.sendNext/sendAll
  · 接受 Return 轻按/长按与展开工具层纸飞机的显式动作；键盘路径固定使用 keyDown token，每个块前重验 token 与 secure input
  · 调用成功后从 live buffer 消费块，并写入最多 50 条内存历史
  · 调用失败即停止，失败块与尚未发送块原位保留
                         │
                         ▼
Delivery.insert(_ text, into: client)
```

- **Delivery.insert 是所有上屏路径的唯一咽喉**——直接 commit、缓冲发送、raw、单字、远端收字，全走它。密码框护栏放在这一处；缓冲路径在上游再做一次可解释的可用性检查。
- **不存在 last/recent client 回退**。目标丢失时发送按钮禁用；发送过程中目标变化则停止在下一块之前，之前成功的块已从 live buffer 消失，失败块与剩余块继续待发送。

---

## 5. UI 架构

### 5.1 输入候选面与独立缓冲工作台

```
普通输入                         缓冲模式（默认）
┌──────────────────────┐       ┌─────────────────────────────────────┐
│ CandidateWindow       │       │ ↑ 工具层（展开后总高 78pt）           │
│ 跟随 caret 的候选面板   │       │ 44pt BufferInlineView 单行主条        │
└──────────────────────┘       └─────────────────────────────────────┘
                                      │ 候选锚点
                               ┌──────▼──────────────────────────────┐
                               │ 同一个 CandidateWindow 常规候选面板  │
                               └─────────────────────────────────────┘
```

- **缓冲工作台是独立 `NSPanel`**：默认 nonactivating，不抢目标输入框焦点；折叠态固定为 44pt 单行细条，只显示缓冲轨与展开入口。目标状态、发送、清空及其余功能统一向上展开，展开后总高 78pt；切换时底边不动，所以条下方候选锚点不跳。窗口可拖动并调整宽度，frame/展开态持久化并在屏幕拓扑变化后夹回可见区域。原来的大预览区、内嵌候选区和底部历史栏已移除，历史改从展开工具层显式恢复。
- **边缘绘制**：圆角材质层内缩到透明窗口边距；边框按 backing scale 以路径内 hairline 绘制，避免把居中 border 压在窗口 bounds 上造成圆角或边缘裁剪毛边。
- **关闭不是清空**：先显式收束当前组字，保存并擦净已打开的块编辑器，暂停捕获，保留全部模型块与历史，再隐藏；secure/隐私/锁屏路径不保存编辑中明文。手动清空有独立按钮并支持一次撤销；隐私选项触发的跨 app 清理不可撤销，并同时删除内存发送历史。
- **常显与多屏**：pin 开启时加入所有桌面与全屏辅助空间；关闭时只属于一个 Space。工作台位于当前 Space 时，常规候选面板使用细条下沿作为锚点；需要时仍可跟随 caret。菜单“显示”会把仍留在旧 Space 的面板重新带到当前 Space，菜单和设置都能把窗口移到鼠标所在屏幕。
- **隐私**：眼睛按钮可临时遮蔽；secure input 隐藏正文、字数与历史控件，并立即关闭、擦净已打开编辑器的隐藏控件。锁屏、睡眠或会话切出会撤销 FocusToken，只在 Rime 内回收/丢弃组字并隐藏窗口；恢复后等待新焦点租约。可选的切 app 清理只认真实外部 A→B，A→本应用窗口→A 不清理；触发时也关闭并擦净编辑器，混有任一外部来源块时则整体保留。
- **候选呈现可配置**：默认把常规 `CandidateWindow` 放在缓冲条下方；用户可切回跟随 caret。两种位置只改变锚点，始终是同一个面板与 token 化选择动作，不存在投影视图或第二份候选状态。
- **外部待决项**：当前仍由 `InboundTrayWindow` 接受/拒绝；异步来源只更新数据，不会自行拉起工作台。`WorkbenchBarView` 仅保留为历史三层方案素材；`panel-render` 已直接渲染真实 `BufferWindowController`，避免预览与运行时再次漂移。

### 5.2 设置窗（两组六页）

```
输入法组                    工作台组
├─ 输入（方案 + 并击间隔）    ├─ 缓冲区（缓冲开关 + 切app重置 + 安全说明）
├─ 候选窗（主题 + 尺寸）      ├─ 连接（配对设备 + 外部来源：MCP/HTTP/SSE/SSH）
└─ 维护（统计/热力图/更新）   └─ 处理器（翻译 + AI）
```

- 缓冲区页真实可用：捕获开关、工作台显隐、常显、候选锚点、移到当前屏幕、跨 app 清理隐私选项与 secure-input 说明都接运行时状态；连接/处理器页部分真实、部分带里程碑标签（诚实标"即将支持"）。
- 「连接」页合并了原「隔空传字」配对、网关开关/端口与接入配置复制；SSE/SSH 只显示未来里程碑。当前没有按来源编辑信任等级或重新生成 token 的 UI。

### 5.3 其它 UI
- **StatusMenu**：系统输入法菜单里的命令入口。
- **InboundTrayWindow**：外部来源收件箱（过渡态，将并入传入轨）。
- **KeyboardHeatmapView**：按键热力图（维护页）。
- **开发预览模式**：`settings-preview/render`、`panel-render`、`gateway-serve` 子命令，无头渲染/验证，不接进正式菜单。

---

## 6. 并发模型

现有代码的最硬约束：IMKit client 只能留在主线程，而翻译/LLM 必然异步。三条规则拆解：

```
① UI 与 IMK 全部主线程       IMK 回调、NSPanel 渲染本来就在主线程，维持现状
② JobRunner 是 actor         每个 TransformJob 一个 Task；onPartial 经 MainActor 串行回写；
                             取消 = task.cancel() + provider 关连接；clear/退出缓冲需级联取消在途 job
③ 投递保持同步               处理器在「入缓冲区侧」跑（结果先落缓冲），投递时无异步依赖；
                             BufferDeliveryCoordinator 在主线程逐块重验 FocusToken 与前台 bundle/PID
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
| 切换应用重置 | 默认跨应用保留；启用后，仅当整个缓冲不含外部来源块时不可撤销地丢弃 blocks、清空撤销快照和发送历史；只要含外部块就全部保留 | ✅ |
| 焦点租约 | 单调 FocusToken + controller/client 对象身份 + client bundle + 前台 bundle/PID + 事件/生命周期归因；无 recent/last client 回退 | ✅ |
| 工作台隐私 | 手动/secure-input 遮蔽正文并关闭编辑器；锁屏/睡眠/会话切出撤销租约且不回写旧 client；编辑器不成为缓冲捕获源 | ✅ |
| 日志脱敏 | 用户文本走 `IMELog.redact()` 只记长度；日志 0600；CI 断言禁 `'\(…)'` 明文 | ✅ M0 |
| 本地端口鉴权 | 只绑 127.0.0.1 + Bearer token（0600）+ 常数时间比较 + 严格解析上限 | ✅ M2 |
| 来源门控 | `SourceTrust` 有询问/信任/拦截三种类型；当前规则固定：Marine 信任，MCP/HTTP/SSE/SSH 询问，无按来源覆盖 UI | ✅ 固定规则；可配置化属后续 |
| echo 防回环 | remotePeer 来源不回镜；规则在 `Origin.allowsRemoteMirror` 与镜像调用点，不依赖尚未实现的 Router | ✅ 规则就位 |
| MCP 隐私边界 | 工具只给不看不发；无读缓冲/读上下文/触发投递工具 | ✅ 写死 |
| 网络出站清单 | 隔空传字与更新检查已存在；AI / SSE / SSH 属后续且默认关 | ✅ 现有两类；其余随 M3–M6 |
| 处理器隐私红线 | 只发用户显式选中的块，不带历史/preedit/剪贴板 | 计划 M3-M4 |

**明确不做**（v1 边界）：剪贴板捕获、AirDrop 目标、Turn/Artifact 完整版本模型、宿主文本撤回。块级显式编辑已实现，但不提供无边界 diff/reconcile 的自由编辑面。

---

## 8. 进程、生命周期、持久化

- **进程**：单进程后台 agent（`LSUIElement`，`.accessory`）。IMKServer 连接名必须与 Info.plist 一致。持进程生命周期。
- **身份三元组冻结**：bundle id `com.isaac.inputmethod.RimeBuffer` + mode `.Hans` + 目录 `ETInput.app`，CI 断言钉死字面值（防重复注册鬼影）。
- **持久化**：
  - UserDefaults：缓冲开关、工作台显隐/frame/常显/候选锚点、跨 app 清理选项、并击时长、候选窗尺寸、网关开关/端口、外观。按来源信任覆盖尚未实现，因此当前不在持久化项中。
  - 仅进程内：缓冲 blocks、最近 50 条发送历史、撤销清空快照；输入法进程重启后不恢复。
  - 0600 文件：gateway-token、remote 身份私钥、（计划）AI 凭据。
  - JSON：按键统计（按日）、Rime 用户配置（`~/Library/RimeBuffer`）。
  - 日志：`~/rimebuffer.log`（0600，脱敏）。
- **自更新**：UpdateManager 每小时查 GitHub Releases（这是隐私清单要计入的第 5 处出站）。
- **发布链**：build_install.sh（dev→~/Library）/ scripts/make-pkg.sh（pkg→/Library）/ CI（编译 + plist 断言 + 日志断言 + 9 个 smoke）/ release.yml（通用二进制）。签名为 ad-hoc（Dev ID 未申请，是钥匙串决策的根因）。

---

## 9. 模块地图（现有源码，约 14000 行）

```
Sources/CRimeBridge/            librime C API 桥（手写 RimeApi + dlopen）
Sources/RimeBuffer/
  main.swift                    IMK 引导、全局接线、dev 子命令、系统观察者
  RimeBufferController.swift    IMKInputController 子类，事件主路径（最大文件）
  RimeEngine.swift              librime 封装（session 生命周期）
  CompositionSession.swift      marked text / preedit
  CandidateWindow.swift         唯一候选状态机/NSPanel + caret/缓冲条锚点
  InputFocusCoordinator.swift   FocusToken / client+前台PID租约 / target-event-lifecycle 规则
  BufferWindowController.swift  44pt 单行条/向上展开至 78pt + 显式块编辑器/历史菜单
  BufferInlineView.swift        工作台待发送 chips（+来源徽标）
  BufferModel.swift             缓冲枢纽（blocks / history / clear undo / transient）
  BufferDeliveryCoordinator.swift 精确目标上的逐块投递与成功块消费
  Origin.swift                  来源溯源 + echo 守卫              [工作台新增]
  Delivery.swift                唯一上屏咽喉 + 密码框护栏
  ChordController.swift         并击 + ChordSettings
  RimeKey/RimeModels/InputSchemaCatalog   键映射/模型/方案目录
  RimeUI.swift                  配色/主题
  StatusMenu.swift              系统输入法菜单命令
  SettingsWindow.swift          设置窗（两组六页）
  WorkbenchBarView.swift        历史三层面板视觉素材（未接运行时）
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
  [计划] Delivery/DeliveryRouter 多目标投递 + 远端 ACK + 持久账本
```

**测试**：无 XCTest target；9 个编进二进制的 smoke 子命令（schema / buffer / buffer-window / stats / matrix / candidate-metrics / origin / inbound / remote），CI 全跑。

- `buffer-window-smoke` 覆盖 focus epoch/弱 lease 清理、target 的 current/expected token 与双 client 身份、前台 bundle/PID、事件顺序、provisional 与 nil-bundle activation、lifecycle/chord 隔离、own-PID 排除，以及只在真实外部 A→B 触发的隐私清理。
- 同一 smoke 还覆盖缓冲 Return 的纯轻按/长按轮询判定（包含轮询延迟但已经抬键时仍按轻按处理）、Return/Backspace 的纯路由 disposition，以及 callback ownership 的 final-block inactive、command-before-keyUp、auto-repeat、遗漏 command 后下一次 fresh press 和 command-only fresh press 转移；另覆盖长按进度状态在隐私遮蔽时清除、active-Space 可见性、loading-only 清空、工作台隐私轨（正常渲染一个块后，shielded refresh 必须擦掉 chip 并保持隐藏）与窗口 geometry：完全离屏时回到 fallback screen、超宽 frame 收进相交 screen、44pt/78pt 高度归一化与底边固定，以及可见区域窄于常规最小宽度时仍能完整放入。真实 IMK 回调顺序、宿主隔离与实际投递仍需安装后的交互回归。
- `buffer-smoke` 覆盖成功块即时消费、局部失败保留、最近 50 条历史、恢复相对顺序、编辑元数据、插入点、清空撤销、暂停保留与不可恢复的隐私丢弃。真实窗口关闭/锁屏和 IMK 交互仍需安装后的真机验证。

---

## 10. 里程碑状态

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M0** 安全底线 | 密码框护栏 / 可选切app清理 / 日志脱敏 | ✅ 发布 0.4.4；当前清理默认关 |
| **M1-A** 来源溯源 | Origin / echo 守卫 / 来源徽标 / Marine 正名 | ✅ 发布 0.4.5 |
| **前端** | 设置两组六页 / 44pt 单行条+向上工具层 / 真实运行时预览入口 | ✅ 发布 0.4.6 |
| **spike** | NWListener HTTP/SSE ✓ · MCP 真 Claude Code ✓ · Apple 翻译无头 ✓ | ✅ 全过 |
| **M2** 网关+MCP | LocalGateway / MCP tools / InboundBus / token / 收件箱 | ✅ 主干+收件箱（0.4.7），传入轨嵌入独立工作台待做 |
| **缓冲窗口** | FocusToken / Return+Backspace 隔离 / 44pt 单行条+78pt 上展 / 常规候选窗下挂 / 成功块消费 / 历史恢复 / 多屏与隐私 | ✅ 2026-07-17 已实现、安装并通过已安装二进制 smoke；待真实宿主输入交互验收 |
| **M3** 处理器+翻译 | JobRunner / Processor / TranslationProcessor / 处理胶囊 UI | 计划 |
| **M4** AI | AIProcessor（SSE） / 凭据 / 通用端点 / 提示词模板 | 计划 |
| **M5** 投递路由 | 本地精确焦点与 50 条内存历史已完成；多目标 / 远端 ACK / 持久账本 | 部分完成 |
| **M6** SSE/SSH + 收尾 | SSE/SSH provider / 传入轨嵌入独立工作台 / 视觉对齐 | 计划 |

**作废/推迟**（产品决策）：远端改道 + 协议 v2（配对走直通上屏）；剪贴板捕获；AirDrop。

---

## 11. 关键约束与已踩的坑（给未来的自己）

1. **身份三元组永不再改**——10 天换 5 代身份造成过 10+ 重复注册鬼影，CI 断言已钉死。
2. **Delivery.insert 是唯一上屏咽喉**——任何新上屏路径都必须走它，安全护栏才生效。
3. **FocusToken 是候选与缓冲投递的共同所有权**——迟到回调只能处理自己的 token；前台 bundle 与 PID 也必须匹配；禁止恢复 `active ?? recent`、`lastClient` 或 bundle-only 投递兜底。
4. **NWListener 连接对象必须持有**——不持有会立刻释放，`weak self` 变 nil，连接静默失效（spike 抓到过）。
5. **异步事件不许拉起候选面板或工作台**——外部待决项可更新专用 nonactivating toast/收件箱提示；工作台显隐只由用户与持久化偏好决定。
6. **处理器必须在入缓冲侧跑**——结果先落块，投递路径保持同步、可逐块重验目标。
7. **翻译需要一次性模型下载**——唯一用到 SwiftUI 的点，放设置窗真窗口里。
8. **钥匙串 vs ad-hoc 签名**——ad-hoc 下钥匙串每次重装弹密码，所有密钥用 0600 文件；拿 Dev ID 后再迁。
