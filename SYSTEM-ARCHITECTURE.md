# Enter输入法 (ETInput) · 系统架构

版本：2026-07-19 · 权威全局架构文档
关系：本文档描述**整个系统**（既有输入核心 + 缓冲工作台）。`WORKBENCH-DESIGN.md` 是工作台的产品方案与决策记录；`ARCHITECTURE.md` 是 P1 时代的交接文档（已滞后，仅存档）。三者冲突时以本文档为准。

代码规模：约 31000 行（Swift + 一层 C++ librime 桥）。单进程、后台 agent（`LSUIElement`）。

---

## 0. 一句话

Enter输入法是一个 **macOS 中文输入法**（IMKit + 自包含 librime），并在其上叠加了一个**独立、常驻、上屏前的文本工作台**：本地打字、已接受的外部文字与用户主动请求的插件结果汇入缓冲区，经人工确认后投递到实时校验的输入框。普通工作台折叠/展开为 44/78pt；苹果本地翻译、Codex CLI、Claude Code CLI 或 OpenAI 兼容 API 打开时改为上 source/下 target 两条缓冲轨，折叠/展开为 78/112pt，拖拽/展开对齐源文行，发送对齐目标行。上层含状态、缓冲插件选择器与当前动作、刷新/重置和关闭；选择器可原地切换全部 `.bufferAction` 插件的唯一 owner。AI 插件只在用户点击生成时读取当前缓冲全文；下方目标块全部成功发送后才消费对应源块。刷新/重置保留源正文，只取消过时任务、重新探测上下文或重启当前生成。`Command+Shift+B` 可从任意应用全局打开工作台并恢复缓冲捕获。工作台本身不提供块编辑器或缓冲开关；候选与 preedit 继续由常规 `CandidateWindow` 呈现，缓冲模式下默认锚定在工作台下方。

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
 已安装 Action Plugin manifest ─▶ ActionPluginHost ─Bearer HTTP─▶ 本机插件服务         │
                          │          │ 有效结果                            │失效结果     │
                          │          └────────────────▶ BufferModel ◀─ Rime │          │
                          │                                      (blocks)  └▶InboundBus│
                          │                                      (blocks)     commit  │
                          │                                Return 手势 / 主条纸飞机       │
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
 Apple 本地翻译──────▶ TranslationWorkspace ──▶ 独立译文缓冲          │
 Codex/Claude CLI ─────▶ AITextPluginWorkspace ──▶ 独立生成缓冲       │
 OpenAI 兼容 API ────────────────────────────────┘
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
| **动作插件层** Action Plugins | 用户明确调用 Marine 等外部动作；冻结上下文并把结果安全地路由回缓冲/收件箱 | ActionPluginHost, manifest, loopback HTTP |
| **加工层** Transforms | 本地翻译与三个显式 AI 生成插件使用独立 source/target 双缓冲 | AppleTranslationWorkspace, AITextPluginWorkspace, CLI/API providers |
| **投递层** Delivery | 把确认后的块送到目标；防过期焦点、防回环、防误投 | InputFocusCoordinator, BufferDeliveryCoordinator, Delivery（唯一插入咽喉） |

下面是底座：**输入核心**（Rime 引擎 + IMKit 事件 + 候选窗），它既独立工作（普通打字），又是缓冲层的一个来源（Rime commit）。

---

## 2. 数据流：一段文字的一生

```
① 本地打字         ② 外部来源                    ③ Action Plugin
   键盘事件           MCP/HTTP；[计划] SSE/SSH       用户点动作 → 本机服务生成
     │                   │                         │
     ▼                   ▼                         ▼
  RimeEngine          LocalGateway              ActionPluginHost
  processKey          → InboundBus.submit        run(input) async
     │ commit            │ 门控                     │ requestId/contextId/FocusToken 校验
     ▼                   ▼                         ▼
  ┌──────────────────────────────────────────────────────┐
  │            BufferModel  (blocks: [Block])             │  ← 枢纽：每个块带 Origin
  │   缓冲模式 OFF → 直接上屏；ON → 暂存为块，等确认        │
  └──────────────────────────────┬───────────────────────┘
                                 │ Return 轻按/长按或点击主条右侧纸飞机
                                 ▼
                     BufferDeliveryCoordinator
                    ┌──── FocusToken/controller/client 身份、bundle 与前台 bundle/PID 精确匹配
                    ├──── 组字未决 / secure input → 拒绝或先显式收束
                    ├──── 每个块投递前再次校验，焦点变化立即停
                    ▼
                Delivery.insert  ──▶ 当前输入框 (client.insertText)
```

关键不变量（安全叙事，恒真）：
1. **非配对外部文字永不自动上屏**——MCP/HTTP 先进收件箱待决；用户主动调用且仍匹配原 request/context/focus 的插件结果可直接进缓冲，失效或迟到结果退回收件箱。
2. **插件/处理器结果永不直接上屏**——无论直接进缓冲还是退回收件箱，都只能由用户随后明确投递。
3. **secure input（密码框）激活时，投递整体禁用**。
4. **缓冲投递不保存“最近输入框”兜底**：只有当前 `FocusToken` 的外部文本框能接收，且租约记录的 bundle 与进程 PID 必须同时匹配当前前台应用；切 app、切文本框或同 bundle 应用重启都会令旧目标失效。
5. **手动投递不等于目标已确认收到**：当前产品在 `Delivery.insert` 成功返回后立即消费 live block，不保留明文发送历史；失败的块和后续尚未发送的块原位保留。
6. **配对设备是来源侧唯一直通例外**：收到的文字沿既有实时传字路径直接上屏，不进入缓冲工作台。
7. **缓冲按键与宿主隔离**：缓冲模式下普通/Shift+Return 与 Backspace 总是被输入法消费。有未决 Rime/并击/raw 输入时，本次 Return 只收束成缓冲块并抑制同一物理按键余下事件；没有未决组字时，轻按发送下一块，按住约 1.2 秒发送全部。Backspace 只在精确焦点下编辑 Rime/并击状态或删除缓冲块。焦点不可信时始终吞键且不投递；引擎故障时，无法安全收束的未决组字只吞不发，但无未决组字的已有块仍可发送。宿主绝不会收到换行或删除。
8. **派生双轨按生成快照交易**：只有已完成且仍匹配 source text/block ids/generation 的 target blocks 可投递；目标块未全部送完时源块原样保留，最后一个目标块成功消费后才一次性消费对应源块。

---

## 3. 领域模型（核心类型）

```
Origin ──────── 文本从哪来。驱动三件事：UI 来源徽标 / echo 防回环 / 来源门控
  case rime                         本地打字（无徽标）
  case marine                       Marine 草稿（兼容期，将并入 mcp）
  case plugin(id)                   用户主动调用的进程外 Action Plugin
  case mcp(client)                  MCP 客户端（自报名，不可验，仅展示）
  case http(source) / sse(feed) / ssh(host)
  case remotePeer(deviceID)         配对 Mac
  case processor(id, allowsRemoteMirror) 本地派生结果

Block (BufferModel 内) ── 缓冲区的一个块；live blocks 均为待发送
  id / text / origin / createdAt
  pluginMetadata? = pluginId/actionId/requestId/contextId/focusToken/runtimeIdentity/title?/targetSummary?/stale/reviewedAsPlainText

InboundItem (InboundBus 内) ── 传入轨上的待决条目
  id / origin / title? / text / streaming / state(pending|accepted|rejected) / pluginMetadata?

AITextPluginWorkspace.Job ── 一次显式 AI 生成
  generation / requestID / sourceText(冻结快照) / sourceBlockIDs
AITextWorkspaceOutputBlock ── 独立 target rail 的逻辑块
  id(按 index 稳定) / index / text / title? / incomplete

```

设计要点：
- **Origin 是这次工作台重构的第一等公民**。一个枚举同时解决徽标、防回环、门控三件事。
- **Action Plugin 结果是带 metadata 的 `BufferModel.Block`**；翻译/AI 结果则先留在独立 target workspace，投递时才经 `BufferDeliveryContentSource` 暴露为 `.processor` Block。
- **source snapshot = 轻量版「Turn 冻结」**：任务启动时拷贝全文与 block IDs，之后任一边发生变化都作废旧 generation，不引入显式 Turn 实体。

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
- **RimeBufferController 按键隔离与 Enter 手势**：缓冲模式在最外层吞掉普通/Shift+Return 与 Backspace。精确外部租约持有缓冲控制期间，`CompositionSession` 会常驻一次不可见 U+200B marked-text guard（包括 Rime 空闲和引擎不可用阶段），防止 Chromium/ProseMirror 在 IMK handled 结果之外观察 raw Return 并提交；guard 生命周期与真实组字状态分离，空闲 guard 不会把 `composition.composing` / lease `compositionActive` 置真，且 marked range 标为不可靠。Return keyDown 绑定当时的 `FocusToken`；有未决组字时只收束并抑制到物理抬起，否则 keyUp 或物理轮询检测到抬起时请求 `sendNext`，持续物理按住到 1.2 秒时请求 `sendAll`。发送动作与 callback ownership 独立：每次被接管的物理按键持有 sticky keyUp / `didCommand(insertNewline:)` suppression，发送最后一个 transient block 令 buffer inactive、动作 reset 或失焦都不能把迟到/重复回调放给宿主；旧字段的 stale callback 不改变当前按压状态，下一次确认的 non-repeat keyDown 才退休旧代并立即按新状态路由。`handle(_:client:)` 是 Return 唯一动作入口，`didCommand` 仅防御性吞命令，不形成第二条发送路径。Backspace 仅在精确租约下改 Rime/缓冲。隔离分支先于 raw fallback，故引擎失败和不可信焦点也不会把这两个键交给宿主。
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
  insert/remove            显式插入与删除；身份、来源和顺序受模型统一维护
  consumeDelivered         成功块原子离开 live blocks，不留明文历史
  clear/discardForPrivacy  仅供内部重置与不可恢复安全清理

BufferDeliveryCoordinator (单例)
  availability             当前精确目标 / 组字 / secure input / 待发送状态
  sendNext / sendAll       由 Return 手势或主条纸飞机触发；每块重验 FocusToken、client 身份、前台 bundle/PID，经 Delivery.insert 投递
```

- **枢纽地位**：Rime commit、外部来源接受、处理器结果，三路最终都进 `blocks`。
- **来源徽标**：非 rime 块在 BufferInlineView 里带彩色点（远端紫/agent 琥珀/网络蓝），rime 块保持干净。
- **消费语义**：`Delivery.insert` 成功返回后，成功块会原子地从 live `blocks` 删除且不保留明文发送历史；失败时立即停止，失败块和未发送后缀保持原顺序。
- **块交互语义**：工作台中的 chip 只被动展示已确立的 Rime commit 边界，不进入选中态、不打开单块编辑器。Backspace 删除、插入点与成功投递仍经 `BufferModel` 的显式方法维护身份和顺序。

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
| Action Plugin | `~/Library/RimeBuffer/plugins/*/manifest.json` 声明动作；按 runtime config 走本机 Bearer HTTP | ✅ 通用宿主；具体插件独立安装 |
| MarineBridge | 旧 `/buffer-state/latest` 轮询实现仍保留源码，但 focus 主路径已解除调用 | 仅兼容存档，不是新链路依赖 |

### 4.4 Action Plugin 宿主与本地翻译工作区

每个插件目录包含 schemaVersion=1 的 `manifest.json`，声明插件 id/name、runtime config 候选路径和动作 `id/title/symbol/statusPath/invokePath/modes`；互斥场景动作还可声明成对的 `presentationId/presentationTitle`。同一插件内共享 presentation id 的动作必须共享标题，工作台只渲染一个按钮，但请求、流事件、结果元数据与发送复核始终保留 status 当前选中的真实 action id。runtime config 只接受 `localhost/127.0.0.1/::1`，必须包含与 manifest 精确相同的 `pluginId` 以及 `apiBase/token/updatedAt`（可附 `instanceId/processId`）；宿主拒绝符号链接、非普通文件、相对路径逃逸和超过 1 MiB 的配置，按更新时间从新到旧探测，跳过已失效的残留配置。一次 status 成功后，invoke、生成后的复核与发送前复核都锁定该精确 runtime binding，期间出现更新的配置也不能把请求切到另一实例。工作台可见时每秒轻量刷新状态，因此“先开缓冲、后选浏览器目标”和“先选目标、后开缓冲”都成立，设置/菜单中的底层缓冲启停本身不参与目标发现。展开区的刷新/重置会取消当前及过时调用、清掉本次失败状态并强制重新获取当前上下文，但不修改 `BufferModel` 正文。

`ActionPluginManager` 管理 `~/Library/RimeBuffer/plugins`：本地安装可复制完整插件目录或单一清单，网络安装只接受 HTTPS `manifest.json`，不解压归档、也不执行安装脚本；安装过程使用同目录暂存与替换，并拒绝异 ID、大小写碰撞及符号链接重定向。底层启用状态仍单独持久化并在损坏时 fail-closed；设置页把安装、卸载、刷新和打开目录收进三个操作弹窗，插件行不再暴露底层启用与当前 owner 两套状态。管理读写串行化，远端下载绑定 mutation generation，后发的启停/卸载可让迟到下载失效，不能复活插件。管理变更通过通知让 `ActionPluginHost` 立即重载；插件被禁用、卸载或升级时，旧动作、在途调用、发送复核和 bearer 绑定同时失效。

动作点击时，宿主冻结 `actionId + requestId + contextId + FocusToken + runtime binding`，但绝不把 IMK client、FocusToken 或 bearer token 交给插件。invoke 完成后用同一 binding 再读取一次 status：响应 id、当前 context 和原焦点租约全部匹配时，结果作为 `.plugin(id)` Block 进入缓冲；任一项失效时，带 `stale=true` 元数据进入 `InboundBus` 等人工接受。用户随后发送仍绑定目标的插件块时，唯一投递协调器还会异步重取同一实例的 fresh status，并在回调后再次核对原 `FocusToken/context/action`；切到另一评论后，迟到的“允许”回调也只能把旧块标记过期，绝不进入 `Delivery.insert`。若用户在收件箱明确选择“作为普通文本加入”，元数据会转为 `reviewedAsPlainText=true`：保留来源和原目标仅供核对，但永久解除旧浏览器绑定，之后像普通块一样只投递到用户当时明确聚焦的输入框。两条生成路径本身都不调用 `Delivery.insert`，因此不会自动上屏。

`BufferPluginSelectionStore` 把 `.bufferAction` 能力收敛为一个当前 owner：Marine、苹果翻译与三个 AI 文本插件在设置中以同一种卡片和唯一 Switch 呈现，展开工作台中的紧凑选择器也直接枚举这些插件。Switch/选择器都直接映射 owner；打开新插件会原子替换旧 owner，选到 disabled 插件会先恢复它的底层启用状态。缓冲插件不会贡献动态“扩展”路由。owner 切换会取消旧 owner 的在途请求、停止其工作台状态并作废旧翻译/AI generation，但**不撤销已完成 Action Plugin block 生成时的投递 authority**：例如切到 Codex 后，已完成的 Marine 块仍可用原 runtime binding/action/context/focus 复核。只有该外部插件被禁用、卸载、升级或原 runtime 失效时，才撤销对应已完成结果的权限。

Apple 翻译不伪装成 HTTP Action Plugin。`AppleTranslationWorkspace` 读取 `BufferModel.stagedText`；界面上方源轨合并显示全文且不分 block，下方目标轨独立显示译文 block，两条轨道分别横向滚动。翻译态中拖拽与展开按钮对齐上方原文行，发送按钮对齐下方目标语言行。AppKit 工作台挂载 1×1 的 `NSHostingView`，通过 SwiftUI `translationTask` 获得只在视图生命周期内有效的 `TranslationSession`。自动刷新采用 single-in-flight + latest-queued：持续输入不会反复取消当前本地会话，完成的旧快照只能作为降透明的“更新中”预览，只有与当前原文和语言完全匹配的 generation 才进入可发送态。用户点击展开区的刷新/重置时，保留原文 `BufferModel`，作废当前译文 generation 并立即重启当前语言组合的翻译。未 review 的 Action Plugin 目标绑定块禁止作为翻译源，避免加工后绕过原焦点/上下文校验。`BufferDeliveryCoordinator` 通过 `BufferDeliveryContentSource` 选择普通缓冲或译文缓冲，并在每个 block 投递前按 workspace/generation/id 重取实时内容。译文 `.processor` 来源继承所有源 block 中最严格的 remote-mirror 策略。

```
当前 BufferModel 全文 ─用户点击生成─▶ AITextPluginWorkspace 冻结 source text + block IDs
                                               │ 单任务；继续输入/切 owner/安全遮蔽即取消或作废
                         ┌─ CodexCLITextProvider ────── Process + stdin + JSONL
                         ├─ ClaudeCodeCLITextProvider ─── Process + stdin + stream-json
                         └─ OpenAICompatibleTextProvider ─ URLSession + chat/completions SSE
                                               │ 每个逻辑 block 用稳定 UUID 原位更新
                                               ▼
                                      下方 target rail（完成后才可发）
```

- **翻译（已实现）**：当前 macOS 15.1 SDK 下使用 SwiftUI `translationTask(configuration)` 桥接；Translation 与 `_Translation_SwiftUI` 弱链接，最低系统仍是 macOS 13，13/14 只显示不可用状态。`prepareTranslation()` 由系统在首次使用语言组合时准备本地模型。
- **Codex/Claude CLI**：输入法用 `Process` 直接启动已登录 CLI，参数固定，源正文只走 stdin，工作目录临时且为 0700，不启用 shell、工具或会话持久化。这是“本地启动 CLI”而不是“本地推理”：点击生成后，缓冲全文会经各自 CLI 当前已登录的服务发送。
- **OpenAI 兼容 API**：在“设置 › 连接器 › AI 模型”配置 Base URL、model 和 API key；端点为 `POST {baseURL}/chat/completions`，支持 SSE 与非流式 JSON fallback。远程地址必须 HTTPS，HTTP 仅允许 loopback，且拒绝 userinfo/query/fragment 与 redirect。配置与密钥存于 0600 文件 `~/Library/RimeBuffer/ai/openai-compatible.json`，不写 UserDefaults 或日志。
- **共同隐私边界**：三个插件都只在用户点击生成时发送当前 `BufferModel.stagedText`，不附带历史、preedit、剪贴板或屏幕上下文。未 review 的 Action Plugin 目标绑定块不能被作为源文。

### 4.5 投递层

```
InputFocusCoordinator.liveTarget(expected: token)
  · controller + client 对象身份 + bundle id + 前台 app 四重一致
  · 自身设置等窗口不是外部投递目标
                         │
                         ▼
BufferDeliveryCoordinator.sendNext/sendAll
  · 接受 Return 轻按/长按与主条纸飞机的显式动作；键盘路径固定使用 keyDown token，每个块前重验 token 与 secure input
  · 调用成功后从 live buffer 消费块，不保留明文发送历史
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
普通输入                         缓冲模式（普通 / 翻译）
┌──────────────────────┐       ┌─────────────────────────────────────┐
│ CandidateWindow       │       │ ↑ 工具层                              │
│ 跟随 caret 的候选面板   │       │ 普通 44pt 单轨 / 翻译 78pt 上下双轨    │
└──────────────────────┘       └─────────────────────────────────────┘
                                      │ 候选锚点
                               ┌──────▼──────────────────────────────┐
                               │ 同一个 CandidateWindow 常规候选面板  │
                               └─────────────────────────────────────┘
```

- **缓冲工作台是独立 `NSPanel`**：默认 nonactivating，不抢目标输入框焦点；普通折叠态为 44pt 单轨，展开后为 78pt。苹果翻译或 AI 文本插件打开时 source rail 在上、target rail 在下，折叠/展开为 78/112pt；两轨拥有独立的 scroll/document。双轨态的拖拽/展开与上方源文行对齐，发送与下方目标行对齐；普通单轨态三者仍居中。上层固定显示状态、紧凑插件选择器与当前动作、刷新/重置与关闭，不再含块编辑器或面板内缓冲开关。切 owner 和展开都固定底边，所以条下方候选锚点不跳。仅拖拽图标能移动窗口，背景与其他控件不能拖；窗口仍可调整宽度，frame/展开态持久化并在屏幕拓扑变化后夹回可见区域。原来的标题/字数、手动遮蔽、历史、清空和工具层发送入口均已移除。
- **全局打开快捷键**：`GlobalHotKeyController` 用 Carbon 注册精确 `Command+Shift+B`，不需 Accessibility 权限，按下后调用 `BufferWindowController.openAndResume()`。它会将位于旧 Space 的非 pin 面板带到当前 Space，显示窗口并把 `BufferModel.enabled` 恢复为 true；该注册快捷键被消费，B 不继续传给前台应用。
- **边缘绘制**：圆角层内缩到透明窗口边距，并覆盖固定的日/夜工作台背景 token，避免 HUD 背景采样破坏对比度；边框按 backing scale 以路径内 hairline 绘制，避免把居中 border 压在窗口 bounds 上造成圆角或边缘裁剪毛边。
- **关闭不会删除已有块**：先显式收束当前组字，暂停捕获，结束 transient 加载/错误状态并保留已有模型块，再隐藏。从设置/输入法菜单显示工作台时会恢复底层捕获。工作台没有手动清空或撤销入口；隐私选项触发的跨 app 清理仍是不可恢复的安全操作。
- **常显与多屏**：pin 开启时加入所有桌面与全屏辅助空间；关闭时只属于一个 Space。工作台位于当前 Space 时，常规候选面板使用细条下沿作为锚点；需要时仍可跟随 caret。菜单“显示”会把仍留在旧 Space 的面板重新带到当前 Space，菜单和设置都能把窗口移到鼠标所在屏幕。
- **隐私**：工作台不再维护手动遮蔽状态；secure input 会隐藏正文并禁用发送与插件动作。锁屏、睡眠或会话切出会撤销 FocusToken，只在 Rime 内回收/丢弃组字并隐藏窗口；恢复后等待新焦点租约。可选的切 app 清理只认真实外部 A→B，A→本应用窗口→A 不清理；混有任一外部来源块时则整体保留。
- **候选呈现可配置**：默认把常规 `CandidateWindow` 放在缓冲条下方；用户可切回跟随 caret。两种位置只改变锚点，始终是同一个面板与 token 化选择动作，不存在投影视图或第二份候选状态。
- **外部待决项**：当前仍由 `InboundTrayWindow` 接受/拒绝；异步来源只更新数据，不会自行拉起工作台。`WorkbenchBarView` 仅保留为历史三层方案素材；`panel-render` 已直接渲染真实 `BufferWindowController`，避免预览与运行时再次漂移。

### 5.2 设置窗（垂直一级导航 + 横向子页）

```
左侧一级导航
├─ 输入法：输入编码 / 键入模式 / 词库
├─ 外观：候选窗 / 主题
├─ 缓冲区：常规 / 工作台
├─ 连接器：隔空传字 / 本地网关 / AI 模型
├─ 插件：全部 / 缓冲插件 / 内置扩展
├─ 维护：更新与重启 / 日志与数据
└─ 扩展（动态）：打字测速、统计、飞耀互击学习……
```

- 每个一级页的子页固定显示在右侧顶部；route/subpage 使用稳定字符串身份，不依赖 sidebar 行号。启停内置扩展后目录会重建；若当前扩展被停用，安全回退到「插件 ▸ 内置扩展」。
- 输入法页明确分开三层：输入编码、键入模式和词库。运行时只暴露经过验证的 Rime 组合方案，不允许三层任意交叉，以免生成不可部署配置。`my_combo` 的产品名是「飞耀互击」；同一 schema 由完整的 `InputConfiguration.keyingMode` 区分并击门禁与互击单侧结算，不能从 schema ID 反推。词库页通过 librime `levers` API 维护真实的 `rime_ice` / `english` 用户学习库，导入是合并，导出是可移植 TSV，不复制 live LevelDB。
- 缓冲区、连接器和外部插件管理仍接真实运行时；“AI 模型”子页展示 Codex/Claude CLI 的服务隐私说明，并管理 OpenAI 兼容 API 的 Base URL、model 与 API key。尚未实现的 SSE/SSH 不显示成可操作假功能。当前没有按来源编辑信任等级或重新生成 token 的 UI。

### 5.3 统一插件平台

- `PluginRegistry` 是发现、命名空间、内置扩展生命周期和统一启停 facade；`PluginKey(domain, rawID)` 防止内置与外部包同名遮蔽。
- **外部缓冲插件**仍完全沿用 Action Plugin v1：`ActionPluginHost + ActionPluginManager` 是执行、runtime binding、授权与撤权的唯一 authority。Registry 不重建 wire metadata，也不能让外部包贡献原生 AppKit 设置页，因此 Marine 兼容路径不变。
- **内置扩展/缓冲插件**是随应用编译的可信模块。统计、打字测速和飞耀互击学习贡献动态设置页；苹果翻译、Codex CLI、Claude Code CLI 与 OpenAI 兼容 API 贡献 `.bufferAction`，在唯一 owner 下互斥运行且不出现为左侧动态扩展页。
- `InputTelemetryBus` 是非消费型、脱敏的主线程观测通道：不携带正文、候选、IMK client、FocusToken、应用或焦点身份。secure input、ETInput 自身窗口和不可信/失焦目标不发事件；字符计数只在真正进入缓冲或 `Delivery.insert` 成功后发布。

### 5.4 其它 UI
- **StatusMenu**：系统输入法菜单里的命令入口。
- **InboundTrayWindow**：外部来源收件箱（过渡态，将并入传入轨）。
- **KeyboardHeatmapView / YearHistoryHeatmapView**：统计内置扩展中的每日键盘热力图与全部历史日历热力图。
- **开发预览模式**：`settings-preview/render`、`panel-render`、`gateway-serve` 子命令，无头渲染/验证，不接进正式菜单。

---

## 6. 并发模型

现有代码的最硬约束：IMKit client 只能留在主线程，而翻译/LLM 必然异步。三条规则拆解：

```
① UI 与 IMK 全部主线程       IMK 回调、NSPanel 渲染本来就在主线程，维持现状
② Provider 在工作队列运行  Apple Translation task / CLI Process / URLSession SSE 不持有 IMK client；
                             它们只携带值类型 source snapshot，回调切回主线程并按 generation 写 workspace
③ 投递仍由协调器串行化   派生 target blocks 先留在独立 workspace；BufferDeliveryCoordinator 为每块
                             重验 workspace/generation/id 与 FocusToken，全部成功后再消费 source
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
| 切换应用重置 | 默认跨应用保留；启用后，仅当整个缓冲不含外部来源块时不可撤销地丢弃 blocks；只要含外部块就全部保留 | ✅ |
| 焦点租约 | 单调 FocusToken + controller/client 对象身份 + client bundle + 前台 bundle/PID + 事件/生命周期归因；无 recent/last client 回退 | ✅ |
| 工作台隐私 | secure-input 自动遮蔽正文并禁用发送/插件动作；锁屏/睡眠/会话切出撤销租约且不回写旧 client；自身设置窗口不成为缓冲捕获源 | ✅ |
| 日志脱敏 | 用户文本走 `IMELog.redact()` 只记长度；日志 0600；CI 断言禁 `'\(…)'` 明文 | ✅ M0 |
| 本地端口鉴权 | 只绑 127.0.0.1 + Bearer token（0600）+ 常数时间比较 + 严格解析上限 | ✅ M2 |
| 来源门控 | `SourceTrust` 有询问/信任/拦截三种类型；当前规则固定：Marine 信任，MCP/HTTP/SSE/SSH 询问，无按来源覆盖 UI | ✅ 固定规则；可配置化属后续 |
| echo 防回环 | remotePeer 来源不回镜；规则在 `Origin.allowsRemoteMirror` 与镜像调用点，不依赖尚未实现的 Router | ✅ 规则就位 |
| MCP 隐私边界 | 工具只给不看不发；无读缓冲/读上下文/触发投递工具 | ✅ 写死 |
| 网络出站清单 | 隔空传字、更新检查与用户显式生成的 Codex/Claude/OpenAI 兼容 API 已存在；SSE 订阅/SSH 仍属后续 | ✅ 已实现项按用户动作或现有设置运行 |
| AI 插件隐私红线 | 只在点击生成时发当前缓冲全文，不带历史/preedit/剪贴板/屏幕上下文；CLI 非本地推理 | ✅ |
| OpenAI 凭据 | Base URL/model/API key 保存到 0600 私有 JSON；拒绝非 HTTPS 远程端点与 redirect | ✅ |

**明确不做**（v1 边界）：剪贴板捕获、AirDrop 目标、Turn/Artifact 完整版本模型、宿主文本撤回，以及工作台内的块级/无边界自由编辑面。

---

## 8. 进程、生命周期、持久化

- **进程**：单进程后台 agent（`LSUIElement`，`.accessory`）。IMKServer 连接名必须与 Info.plist 一致。持进程生命周期。
- **身份三元组冻结**：bundle id `com.isaac.inputmethod.RimeBuffer` + mode `.Hans` + 目录 `ETInput.app`，CI 断言钉死字面值（防重复注册鬼影）。
- **持久化**：
  - UserDefaults：缓冲开关、工作台显隐/frame/常显/候选锚点、跨 app 清理选项、并击时长、候选窗尺寸、网关开关/端口、外观。按来源信任覆盖尚未实现，因此当前不在持久化项中。
  - 仅进程内：缓冲 blocks；输入法进程重启后不恢复，发送历史与清空撤销不再保留。
  - 0600 文件：gateway-token、remote 身份私钥、`ai/openai-compatible.json`（Base URL/model/API key）。
  - 0600 JSON：按键统计（按日 + 全历史）、打字测速聚合、飞耀互击学习进度；测速中的“成文字符”按 Rime commit 计数（直输或进入缓冲均计入），只保存数量、不保存正文；损坏、超限或非普通文件均 fail-closed，不覆盖原数据。
  - Rime 用户数据：`~/Library/RimeBuffer`；词库维护只经官方 `levers` 导入/导出 portable TSV 或恢复官方快照，不直接复制/修改 LevelDB。
  - 日志：`~/rimebuffer.log`（0600，脱敏）。
- **自更新**：UpdateManager 每小时查 GitHub Releases（这是隐私清单要计入的第 5 处出站）。
- **发布链**：build_install.sh（dev→~/Library）/ scripts/make-pkg.sh（pkg→/Library）/ CI（编译 + plist 断言 + 日志断言 + smoke 组）/ release.yml（通用二进制）。签名为 ad-hoc（Dev ID 未申请，是钥匙串决策的根因）。

---

## 9. 模块地图（现有源码，约 31000 行）

```
Sources/CRimeBridge/            librime C API 桥（手写 RimeApi + dlopen）
Sources/RimeBuffer/
  main.swift                    IMK 引导、全局接线、dev 子命令、系统观察者
  RimeBufferController.swift    IMKInputController 子类，事件主路径（最大文件）
  RimeEngine.swift              librime 封装（session 生命周期）
  CompositionSession.swift      marked text / preedit
  CandidateWindow.swift         唯一候选状态机/NSPanel + caret/缓冲条锚点
  InputFocusCoordinator.swift   FocusToken / client+前台PID租约 / target-event-lifecycle 规则
  BufferWindowController.swift  普通44/78pt、翻译双轨78/112pt + 状态/插件动作/刷新/关闭
  BufferInlineView.swift        工作台待发送 chips（+来源徽标）
  BufferModel.swift             缓冲枢纽（blocks / 成功消费 / transient；无发送历史）
  BufferDeliveryCoordinator.swift 精确目标上的逐块投递与成功块消费
  GlobalHotKeyController.swift    Command+Shift+B 进程级全局打开/恢复
  ActionPlugins.swift            manifest/runtime config/Bearer HTTP/动作生命周期与安全分流
  ActionPluginManager.swift      插件安装/下载/启停/卸载与原子文件事务
  Origin.swift                  来源溯源 + echo 守卫              [工作台新增]
  Delivery.swift                唯一上屏咽喉 + 密码框护栏
  ChordController.swift         并击 + ChordSettings
  RimeKey/RimeModels/InputSchemaCatalog   键映射/模型/方案目录
  RimeUI.swift                  配色/主题
  StatusMenu.swift              系统输入法菜单命令
  SettingsWindow.swift          垂直一级导航 + 横向子页设置壳
  SettingsRouting.swift         稳定 route/subpage + 动态扩展目录与回退
  PluginPlatform/BuiltInPlugins 统一 Registry、能力模型与内置扩展生命周期
  InputTelemetry.swift          无正文/无 IMK 对象的本地输入观测总线
  UserLexiconService.swift      官方 user_dict 导入/导出/快照恢复
  WorkbenchBarView.swift        历史三层面板视觉素材（未接运行时）
  KeyFrequencyStore/KeyboardHeatmapView/YearHistoryHeatmapView 按日与全历史热力图
  TypingSpeedStore/TypingSpeedSettingsViewController 本地聚合测速
  FlyChordLearning*             方案派生课程、专项练习与本地进度
  UpdateManager.swift           自更新
  MarineBridge.swift            旧 Marine 轮询源码（主路径未引用）
  Log.swift                     IMELog + redact
  Remote/                       隔空传字（X25519+AES-GCM 双向 + 配对）
    RemoteTypingService / RemoteConfig / RemoteIdentity / RemoteProtocol
  Inbound/                      来源层                          [工作台新增]
    InboundBus.swift            汇聚 + 门控 + 背压 + 流式
    LocalGateway.swift          回环 HTTP/MCP 服务器
    GatewayToken.swift          0600 token
    InboundTrayWindow.swift     外部来源收件箱（过渡 UI）
  AppleTranslationPlugin.swift  本地翻译双缓冲 / SwiftUI session 桥 / 语言设置
  AITextPlugins.swift          Codex/Claude CLI、OpenAI 兼容 API provider、source/target workspace 与 0600 配置
  [计划] Delivery/DeliveryRouter 多目标投递 + 远端 ACK + 持久账本
```

**测试**：无 XCTest target；CI 运行编进二进制的 smoke 子命令。`schema-smoke` 覆盖编码/键入映射与旧偏好迁移，`plugin-platform-smoke` 覆盖缓冲插件单选，`translation-smoke` 覆盖 latest-wins、debounce/max-wait、译文专用投递、部分失败保留与 remote echo 继承。`ai-text-smoke` 用假 CLI runner/provider 与本地 URL fixture 覆盖 Codex/Claude 参数、JSONL/SSE 解析、OpenAI URL/请求、0600 配置、稳定流式 block、源快照作废、完整 target 投递后才消费 source 与 Action Plugin 源洗权拒绝；它不会调用真实 CLI/API。真实 librime 词库桥另有强制隔离 `RIMEBUFFER_USER_DIR` 的 `user-lexicon-bridge-smoke`，不触碰 live 用户库。

- `plugin-smoke` 覆盖 manifest 发现与 schema、上下文动作单控件聚合及 `status.actionId` 动态切换、`~`/相对 runtime path、runtime 从新到旧回退与 status→invoke 精确绑定、只允许 loopback、流式 1 MiB 响应上限、Bearer request、request/context/action/focus 路由规则、切 owner 后已完成 Marine block 仍保留原投递 authority、切换评论后迟到校验不得上屏、收件箱满载显式失败，以及 stale 结果经人工接受后保留来源但安全降级为普通文本。

- `buffer-window-smoke` 覆盖 focus epoch/弱 lease 清理、target 的 current/expected token 与双 client 身份、前台 bundle/PID、事件顺序、provisional 与 nil-bundle activation、lifecycle/chord 隔离、own-PID 排除，以及只在真实外部 A→B 触发的隐私清理。
- 同一 smoke 还覆盖工作台布局契约（主条 drag/disclosure/rail/send、展开层 status/plugin-selector+actions/refresh/close、仅 drag handle 可移动、状态不泄露应用去向）、`Command+Shift+B` 精确全局路由、缓冲 Return 的纯轻按/长按轮询判定、Return/Backspace 路由与 callback ownership；另覆盖长按进度在 secure-input 遮蔽时清除、派生 source/target 上下双轨与拖拽/展开/发送的分行对齐、active-Space 可见性和窗口 geometry：完全离屏时回到 fallback screen、超宽 frame 收进相交 screen、普通 44/78pt 与双轨 78/112pt 的高度归一化和底边固定，以及可见区域窄于常规最小宽度时仍能完整放入。真实 IMK 回调顺序、宿主隔离与实际投递仍需安装后的交互回归。
- `buffer-smoke` 覆盖成功块即时消费且不留历史、未发送块顺序、插入点、暂停保留、transient 状态清理与不可恢复的隐私丢弃。真实窗口关闭/锁屏和 IMK 交互仍需安装后的真机验证。

---

## 10. 里程碑状态

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M0** 安全底线 | 密码框护栏 / 可选切app清理 / 日志脱敏 | ✅ 发布 0.4.4；当前清理默认关 |
| **M1-A** 来源溯源 | Origin / echo 守卫 / 来源徽标 / Marine 正名 | ✅ 发布 0.4.5 |
| **前端** | 垂直一级导航+横向子页+动态扩展 / 44pt 单行条+稳定插件区 / 真实运行时预览入口 | ✅ 2026-07-19 已实现；待真实宿主验收 |
| **spike** | NWListener HTTP/SSE ✓ · MCP 真 Claude Code ✓ · Apple Translation 弱链接/SwiftUI 桥 ✓ | ✅ 全过 |
| **M2** 网关+MCP | LocalGateway / MCP tools / InboundBus / token / 收件箱 | ✅ 主干+收件箱（0.4.7），传入轨嵌入独立工作台待做 |
| **缓冲窗口** | FocusToken / Return+Backspace 隔离 / 44pt 简化主条+78pt 上展 / 常规候选窗下挂 / 成功块无历史消费 / 多屏与隐私 | ✅ 2026-07-18 已实现并通过源码 smoke；待安装后真实宿主输入交互验收 |
| **Action Plugin v1** | manifest/runtime config/loopback Bearer HTTP/动态动作 UI/插件管理/FocusToken+context 安全分流 | ✅ 2026-07-18 已实现；具体插件另行安装 |
| **M3** 本地翻译 | 独立双缓冲 / SwiftUI Translation 桥 / 语言选择 / 互斥撤权 | ✅ 已实现；待安装后真语言包验收 |
| **M4** AI 缓冲插件 | Codex CLI / Claude Code CLI / OpenAI 兼容 API / 双轨 workspace / 0600 凭据 | ✅ 2026-07-19 已实现；通用提示词模板后续 |
| **M5** 投递路由 | 本地精确焦点已完成；多目标 / 远端 ACK / 持久账本仍属后续，当前明确不保存发送历史 | 部分完成 |
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
7. **翻译 session 不得离开 SwiftUI 视图生命周期**——工作台内 1×1 `NSHostingView` 承载 `translationTask`；切插件、安全输入、锁屏和关闭时作废 generation。首次语言组合仍可由 macOS 请求下载本地模型。
8. **钥匙串 vs ad-hoc 签名**——ad-hoc 下钥匙串每次重装弹密码，所有密钥用 0600 文件；拿 Dev ID 后再迁。
9. **owner 不等于已完成块的 authority**——工作台切插件只取消在途工作；已完成 Marine 块必须继续用生成时 runtime/context/focus 校验，不得因 owner 变更而永久失去或绕过权限。
