# RimeBuffer P1/P2 历史架构（交接版 v2）

> 本文保留 P1/P2 的设计动因、marked-text 契约与踩坑记录。当前系统结构、缓冲工作台与里程碑
> 以 `SYSTEM-ARCHITECTURE.md` 为准；本文与其冲突时以后者为准。
> v2 与 v1 设计（11-agent 工作流产物）的**最大差异**：真机实测证伪了
> "永不 setMarkedText" 的假设，组字协议全面改为 **marked-text 会话常驻**（§4）。
> 修改本文档时保持"先说做什么、再说为什么"的写法。
>
> **2026-07-19 当前缓冲 UI/按键覆盖**：工作台折叠为 44pt 单行细条，主条固定为拖拽图标、展开箭头、缓冲块轨和右侧发送按钮；向上展开到总高 78pt 后依次显示无去向信息的状态文字、插件动作、刷新/重置和关闭。刷新/重置保留缓冲正文，只取消过时插件任务、重新检测上下文或重启当前翻译。工作台不再提供块编辑器或面板内缓冲开关，缓冲启停仍由设置/输入法菜单管理。展开前后底边与候选锚点不动；缓冲模式复用常规 `CandidateWindow`，默认显示在细条下方。普通/Shift+Return 与 Backspace 在缓冲模式下永不落到宿主文本框：若有未决组字/并击，本次 Return 只收束为块；否则轻按发送下一块，按住约 1.2 秒发送全部，条底部显示按住进度。成功发送的 block 立即从 live buffer 消失且不保留发送历史；失败和未发送 block 保留。本文若有更早的投影/留块描述，以本条和 `SYSTEM-ARCHITECTURE.md` 为准。
>
> **2026-07-19 输入配置/翻译覆盖**：设置层已把输入编码（自然码双拼/全拼/英文）与键入模式（串击/并击/互击）拆开，再映射到经过验证的固定 schema。飞耀互击复用 `my_combo`：并击由宿主门禁要求同一批左右半区都参与；互击允许左侧声母、右侧韵母独立结算，也保留跨区同时击打。苹果本地翻译已作为内置缓冲插件实现：只出现在缓冲插件列表，与 Marine 共用唯一 owner；源文在上方连续缓冲轨显示，译文在下方独立分块轨显示，拖拽/展开与原文行对齐，发送与目标语言行对齐，只能经 `BufferDeliveryCoordinator -> Delivery.insert` 手动发送。
>
> **2026-07-19 AI 缓冲插件/全局快捷键覆盖**：Codex CLI、Claude Code CLI 与 OpenAI 兼容 API 已作为三个互斥的内置 `.bufferAction` 实现。它们由用户在工作台显式点击生成，把当前缓冲全文冻结为上方 source rail，并在下方 target rail 以稳定 block 更新结果；只有目标块全部成功投递后才消费对应源块。工作台展开层的插件选择器可直接切换全部缓冲插件；切换 owner 不撤销已完成 Marine 结果原有的 runtime/context/focus 复核权限。`Command+Shift+B` 通过进程级全局快捷键打开工作台并恢复缓冲捕获。

---

## 0. 一页速览

| 项 | 内容 |
|---|---|
| 定位 | 从零做的现代 macOS 输入法：**librime 引擎 + 自绘 UI + 常驻缓冲区(buffer)**，终点是替代 Squirrel 成为用户日常主力 |
| 仓库 | `~/Documents/05-dev/apps/rime-buffer`（SwiftPM：C++ 桥 target + Swift executable） |
| 进程模型 | **内部单进程**。IMK、librime、候选窗、buffer、网关、菜单都在同一进程；禁止把内部 UI/状态拆成依赖轮询或 IPC 的伴随进程。MCP/HTTP 与配对传字是明确的外部接口，不在此禁令内 |
| 引擎 | 优先 dlopen app 自带的 `librime.1.dylib` + lua/octagram/predict 插件；开发态才回退 Squirrel 路径；用户数据独立在 `~/Library/RimeBuffer` |
| 上屏 | 只经 `client.insertText`（IMK 一等公民通道，网页/Electron/原生通吃） |
| 已验证 | 引擎 smoke 覆盖四方案列表、F4、雾凇拼音上屏，以及英文补全/空格/生词兜底；.app 可安装可注册可输入 |
| 当前状态 | §4 的 3 个现场 bug 对应修复已落地；§9 P1' 保留为历史验收记录，当前仍需安装后真机回归 |
| 兜底 | Squirrel 保持安装不动，用户随时切回；引擎宕机时输入法自动退化为原生 latin 直通 |

---

## 1. 产品定位与目标

### 1.1 为什么做（动因链）

1. 用户原型 BufferBar（`~/Documents/05-dev/apps/buffer-bar`）用辅助功能(AX)/模拟粘贴向任意输入框注入文字 → **网页/Electron 输入框千奇百怪，AX 写入假成功、粘贴抢焦点失败**，逐 App 调试不可持续。
2. 用户使用 Rime **并击（chord，my_combo 方案）**，在"有钩子的输入框"（Electron/终端等）里组字会被打断——根因指向 Squirrel `inline_preedit: true` 依赖目标框的 marked-text 会话，而这些框处理 marked text 不可靠。
3. 结论：**要可靠地把字送进任意焦点框，必须自己就是输入法**（`insertText` 是唯一一等公民通道）；要保住 Rime 体验，就内嵌 librime + 用户既有配置。
4. 顺势升级：参照微信/豆包输入法的形态 = 引擎 + 富 UI + 服务。用户手里已有深度定制的顶级引擎（librime + 30+ Lua），缺的只是现代前端。**buffer（缓冲区）是本产品的差异化杀手锏**：输入法内部的一等暂存平台，未来挂 AI 改写/翻译、语音、模板、多目标投递。

### 1.2 目标（按优先级）

1. **P1 日常可打**：并击、自然码双拼、雾凇拼音、英文四方案在 Safari、Electron、终端全部正常；候选窗自绘；insertText 上屏；引擎宕机不砸打字。
2. **P2 buffer 平台**：提交文字可先落缓冲面板，分块暂存后再冲刷到目标框。
3. **P3 语音 + AI**：在 buffer 上做听写和 AI 变换。
4. **P4 转正**：学习词同步/迁移、per-app 精调、签名公证、设为默认。进程内 maintenance/deploy 与自包含 runtime 已提前完成。

### 1.3 非目标

- 不覆盖 Rime 全生态——只需服务**这个用户的**方案与习惯（§2）。
- 不做旧 ai_box 方案（Rime Lua 内候选行缓冲，用户已放弃；本项目的 buffer 是原生 UI 层方案）。
- 不修改用户的 `~/Library/Rime`（只读复制）。

---

## 2. 用户环境画像（实现时的"合同"）

来源：`~/Library/Rime`（git 管理）。**以下每一条都是实测/实读得出，直接决定实现细节。**

| 项 | 值 | 对实现的约束 |
|---|---|---|
| 用户可见方案 | `my_combo`（并击）/ `double_pinyin`（自然码）/ `rime_ice`（雾凇拼音）/ `english`（英文） | 只有这四项进入 schema_list 与 F4；melt_eng/radical_pinyin 只作隐藏依赖 |
| 默认方案 | my_combo | 系统输入法菜单需能进入设置并切换 |
| `page_size` | **9**（default.custom.yaml patch；default.yaml 原值 5） | 候选窗渲染 `menu.page_size` 行，**不许硬编码** |
| 并击间隔 | 当前 UserDefaults `chord.duration`，默认 **0.10s**，范围 0.02–0.50s | `ChordSettings` 是唯一运行时来源；设置修改会通知所有活跃 controller，旧 `squirrel.yaml chord_duration` 不再驱动运行时 |
| 方案切换热键 | **F4 / Control+grave / Control+Shift+grave**（default.yaml switcher） | 键位表必须映射 F 键与 grave；切换器以**候选形式**渲染（就是一页候选），候选窗必须能正确显示它 |
| 标点切换 | Control+Shift+3 / Control+Shift+numbersign 绑定 ascii_punct | **修饰键组合必须先喂 Rime**，不许一刀切丢弃 |
| ascii 开关 | Shift_L=commit_code、good_old_caps_lock: true | flagsChanged 按下/抬起事件流的时序**逐字节保持原型行为** |
| 外观 | stacked 竖排、font_point 20、label_font_point 14、purity_of_form_custom 配色、inline_preedit: true | 候选窗视觉对齐目标；组字默认**内联**（marked text 显示 preedit） |
| Lua | 30+ 脚本（含 mode_switch、autocap、长词过滤等） | 引擎必须带 lua 模块；Lua 卡死是已知"打不出字"向量（→watchdog） |
| Squirrel | 可继续安装作用户手动兜底和开发构建的 runtime fallback | 正式 app 已自带 librime 与 Rime 数据，不再把 Squirrel 视为运行依赖 |

---

## 3. 三条铁律（违反即架构事故）

1. **内部单进程，零轮询式组件 IPC。** 候选窗、buffer、菜单、网关全部在 IME 进程内。前身项目把候选 UI 拆到另一进程、经 `~/Library/Rime/tmp/.../state.json` 轮询同步，造成"UI 进程没起来→打不出字"的脆弱链——**此模式永久禁止**。对本地智能体与配对设备开放的 MCP/HTTP/加密网络接口不改变这条内部拓扑约束。
2. **C 桥是 ground truth，逐字复用。** `Sources/CRimeBridge/CRimeBridge.cpp` 的 RimeApi vtable 是对着用户机器上 librime 1.16.0 实测通过的，**字段顺序 load-bearing**（声明顺序=内存布局，动一行就静默错位）。改桥只允许"追加包装函数"，不允许重排/删减 vtable。
3. **上屏唯一出口 + 永活兜底。** 所有文字（普通提交/chord 提交/裸兜底）只经 `Delivery.insert`（`client.insertText`）。缓冲关闭时，任何按键路径在"引擎不健康或 session==0"时必须落到裸 insertText（可打印字符直通、Return→`\n`），**不存在"返回 false 且丢掉一个可打印字符"的路径**。缓冲开启时有一条刻意的隔离例外：普通/Shift+Return 与 Backspace 必须吞键，绝不进入宿主文本框，即使引擎故障或焦点租约不可信也一样。

---

## 4. ⚠️ 实测修正（v2 核心，接手者必读）

2026-07-04 真机实测（用户在微信等 App 实打）发现 3 个问题；结合 Squirrel 源码
（`sources/SquirrelInputController.swift`）取证，v1 的一个核心假设被推翻。

### 4.1 三个现场 bug 与根因

| # | 现象 | 根因 |
|---|---|---|
| 1 | 候选窗死在屏幕下方，"几乎不计算位置" | 无 marked-text 会话时，`attributes(forCharacterIndex:lineHeightRectangle:)` 在多数 App 返回零矩形 → 永远走兜底锚点 |
| 2 | 微信里 "zuoye作业"——**原始字母残留** + 提交文字一起上屏 | 我们从不 `setMarkedText`，客户端不知道"正在组字"，自行回显了原始按键。Squirrel 源码注释明确此坑："用全角空格占位，防止 iTerm2 回显原始编码" |
| 3 | 切不到并击方案 | 键位表没映射 F4（keyCode 118）和 grave（keyCode 50）→ 切换热键根本没进 Rime；即使进了，方案选单以候选渲染，又被 bug#1 藏在屏幕角落 |

### 4.2 结论：组字协议 v2

**marked-text 会话必须常驻（composing 期间始终存在），内容可以极简。** 这是 Squirrel 的实证做法：

- `inline` 模式（默认，匹配用户 `inline_preedit: true`）：`setMarkedText(带下划线的 preedit, selectionRange: caret 位置)`——客户端内联显示组字串。
- `placeholder` 模式（per-app 备选，对付 marked text 处理糟糕的 App）：组字期间 `setMarkedText("　")`（**全角空格**，Squirrel 同款；半角会导致中文基线跳动）——会话存在（不回显、不丢事件、光标矩形可用），但目标框只见一个占位符，preedit 全在我们候选窗里。
- 提交：`client.insertText(text, replacementRange: NSRange(NSNotFound,0))`——有活动 marked 会话时按协议**原子替换** marked 区。
- 取消/失焦：`setMarkedText("")` 清会话（或先提交再清，见 §5.8 策略）。

这同时治好 #1（有会话后光标矩形 API 恢复工作）与 #2（客户端不再回显）。
**原"永不 setMarkedText 以保并击"的担忧**由 per-app `placeholder` 模式 + chord 组字期极短（~50ms 即提交）来覆盖；若某 App 仍坏，加入 per-app 表（§5.4）单独处置，而不是全局裸奔。

---

## 5. 分层架构与模块规格

```
┌─ ETInput.app (IMK 输入法进程, LSUIElement=true, LSBackgroundOnly=false, .accessory) ┐
│                                                                              │
│  main.swift ── IMKServer 引导 · 引擎预热 · 系统输入法菜单状态                  │
│                                                                              │
│  RimeBufferController (IMKInputController, 每个客户端一个实例)                │
│    │  键路由: keysym 映射 → processRimeKey → commit drain → UI 更新           │
│    ├─ CompositionSession   ★v2 组字协议(marked text 常驻, inline/placeholder) │
│    ├─ ChordController      并击重放(仅 my_combo; duration=ChordSettings)     │
│    ├─ CandidateWindow      唯一候选 panel：锚定 caret / 缓冲条下方           │
│    ├─ InputFocusCoordinator FocusToken + 当前 IMK client 租约                │
│    ├─ StatusMenu           IMK menu() 构建器(设置/健康/更新/重载)             │
│    ├─ FocusObserver        失焦强制 flush chord + 提交/清组字                 │
│    └─ Delivery             唯一上屏出口 insertText                            │
│                                                                              │
│  RimeEngine (可实例化封装, 每控制器独立 session) ── CRimeBridge (C++, dlopen) │
│    └─ app 自带 librime.1.dylib + lua/octagram/predict；开发态回退 Squirrel   │
│    └─ 用户目录: ~/Library/RimeBuffer (自 ~/Library/Rime 播种的独立副本)        │
│                                                                              │
│  BufferWindowController + BufferModel + BufferDeliveryCoordinator             │
│  AITextPlugins(已实现)  [P3] 语音  [P4] 学习词同步/签名公证             │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 5.1 CRimeBridge（C++，`Sources/CRimeBridge/`）— 状态：✅ 已改造并验证

- 职责：优先从 app Frameworks dlopen 4 个 dylib（RTLD_NOW|RTLD_GLOBAL；开发态回退 Squirrel）→ `rime_get_api` → `setup()+initialize()` → `start_maintenance`/`deploy_config_file` 在独立用户目录生成 build → smoke session 健康门控。
- 已提供：`BBRimeStart/IsHealthy/CreateSession/DestroySession/ProcessKey/CommitComposition/ClearComposition/SelectCandidateOnCurrentPage/GetOption/SetOption/SelectSchema/Deploy/GetContext/GetStatus/CopyCommit/CopySchema/CopyLastError/FreeString`。
- `BBRimeGetContext` 语义：填**当前页**（librime 的 menu.candidates 本来就是按页数组）——preedit/光标、page_size/page_no/is_last_page、高亮下标、候选 text/comment/label（label 优先 select_labels，退 select_keys，再退序号）。字符串指针由桥的静态后备存储持有，**仅在下一次调用前有效**，Swift 侧立即拷贝。
- 所有权契约：C 侧 malloc → Swift `String(cString:)` → `BBRimeFreeString`。全部入口锁 `gMutex`。
- `BBRimeConfigGetDouble(configId, key, out)` 已实现，仍可读取部署配置；并击时长已经迁到 `ChordSettings`，不再调用它作为运行时来源。

### 5.2 RimeEngine（Swift）— 状态：✅ 已写

可实例化（**无单例、无共享 session**——前身的共享 session 会让组字状态跨输入框串扰）。`start()` 失败时保持可重试。用户目录默认 `~/Library/RimeBuffer`，环境变量 `RIMEBUFFER_USER_DIR` 可覆盖（CLI smoke 用）。

### 5.3 RimeBufferController — 状态：✅ 已实现并持续演进

- **每控制器一个 session**：`activateServer` 建（懒）、`deactivateServer` flush+提交、`deinit` 先停 chord 定时器再销毁 session。
- **焦点进入时镜像全局开关**：读/写 ascii_mode、simplification、ascii_punct（等 UserDefaults 记忆值），让"简繁/中英"体感全局（Squirrel 是单 session 天然全局，我们要显式镜像）。
- **键路由规则**（顺序敏感）：
  1. `recognizedEvents` = keyDown | keyUp | flagsChanged。`keyUp` 继续用于完整的修饰键/并击生命周期；缓冲区 Return 由 keyDown 绑定焦点租约，keyUp 或物理轮询检测到抬起时判定轻按发送一块，持续物理按住达到 1.2 秒时发送全部。
  2. keysym 映射表 = 原型 `RimeKey` 全表 **+ 增补**：F1–F12（X11 keysym `0xffbe + n`，F4 = `0xffc1`；Mac keyCode F4=118 等），grave（keyCode 50 → `0x60`），数字行/符号经 `event.characters` 直通已可用。
  3. **修饰键组合先喂 Rime**（带完整 mask 调 processKey）；Rime 未处理且 mask 含 command/control 时才 return false 放行给 App（Cmd-C 等正常）。**禁止**一刀切 `guard modifiers.isEmpty`。
  4. flagsChanged 的按下/抬起流与 caps 的 `mask ^ lockMask` 逻辑**逐字节保持原型**（Shift_L=commit_code、good_old_caps_lock 依赖精确时序）。
  5. 非 chord 键按下先 `flushChordRelease()` 再处理。
  6. 每次 processKey 后：drain commit → CompositionSession 更新 marked text → CandidateWindow 更新。
  7. 兜底不变式见 §3-3。
  8. **缓冲按键隔离**：普通/Shift+Return 与 Backspace 在最外层被无条件消费。有未决 Rime/并击/raw 输入时，本次 Return 只把它收束成缓冲块并吞掉同一物理按键的 repeat/keyUp；没有未决组字时，轻按请求 `sendNext`、按住 1.2 秒请求 `sendAll`。Return 的发送动作状态与 IMK callback ownership 分离：被接管的 keyDown 独立持有 sticky keyUp / `didCommand(insertNewline:)` suppression；发送最后一个 transient block、失焦或动作 reset 都不能撤销它们，迟到或重复回调也不消耗当前代的保护，直到下一次确认的新物理按压才退休。`handle(_:client:)` 是 Return 唯一动作入口，`didCommand` 只做防御性消费，不得形成第二条发送路径。Backspace 仅在精确焦点下编辑 Rime/并击状态或删除缓冲块。焦点不可信时始终吞键且不投递；引擎不可用时，无法安全收束的未决组字只吞不发，但没有未决组字的已有块仍可发送。任何分支都不得把换行/删除交给宿主。
- `commitComposition(_:)`（IMK 回调）：flush chord → `commit_composition` → drain → 清 marked。
- **焦点所有权**：每次 `activateServer` 建立新的单调 `FocusToken`；键事件只复用当前精确租约。controller/client 对象身份、`controller.client()` 当前身份、bundle、前台 app PID 与事件顺序共同拒绝迟到回调；生命周期回调不得用 `lastClient` 兜底。explicit、nil 或 non-client sender 都必须与当前隐式 client 一致；同一 proxy（包括跨 controller）被新 epoch 复用后，旧 session 只在 Rime 内回收到缓冲或丢弃。异步和弦回放、弱 client 过期、锁屏/睡眠也走同一 no-client 清理，不靠超时猜测归属。

### 5.4 CompositionSession ★v2 核心— 状态：✅ 已实现

- 状态机：语义上仍是 `idle ⇄ composing`，但精确外部缓冲租约存在时，宿主侧会在 idle 阶段常驻一个不可见 U+200B marked guard，防止 Chromium 类输入框越过 IMK 消费 raw Return。这个 guard 不等于组字：idle 时 `composition.composing` 与 lease `compositionActive` 都为 false，marked range 也不参与字段切换判断；失焦、关闭缓冲、安全输入或进入自有窗口时清除。composing 期间**每次上下文变化都刷新 marked text**；普通模式离开 composing 时结束会话。
- 内容策略（per-app 查表，默认 `inline`）：
  - `inline`：`NSAttributedString(preedit, 下划线)`，`selectionRange` 置于 `cursorPos`；
  - `placeholder`：全角空格 `"　"`。
- per-app 表：`bundleId → .inline | .placeholder`，UserDefaults 持久化；初始为空表（全 inline）。当前没有 StatusMenu/设置页编辑入口，需直接写偏好或后续补 UI。
- 提交路径：`Delivery.insert`（insertText 自动替换 marked 区）→ 若 Rime 仍在组字（长句剩余部分）→ 立刻 setMarkedText(新 preedit)；否则清会话。
- **切勿**在同一客户端同时"设 marked text"又"把 preedit 画在自己面板里重复显示"——inline 模式候选窗只画候选，placeholder 模式候选窗才画 preedit 行。

### 5.5 CandidateWindow — 状态：✅ 单一候选面板与双锚点已实现

- NSPanel（borderless + nonactivating，`.popUpMenu` 层级，canJoinAllSpaces + fullScreenAuxiliary + stationary，orderFrontRegardless）。宿主进程必须 `NSApp.setActivationPolicy(.accessory)`（纯 LSBackgroundOnly 应用不能可靠置窗，已在 main.swift 落实）。
- 渲染：`page_size` 行（用户=9）· label 用 librime select_labels · 高亮行 `highlightedIndex` · comment 淡色 · 翻页指示（page_no/is_last_page）· stacked 竖排 · 字号对齐用户（候选 20pt/标签 14pt）· 配色向 purity_of_form_custom 靠（P4 精调）。
- **定位链**（每次更新执行）：
  1. `client.attributes(forCharacterIndex: <marked 区 caret 下标>, lineHeightRectangle: &rect)`——有 marked 会话后这是可靠主路径（Squirrel 同款）；窗放 rect 下沿、必要时翻到上方防出屏。
  2. rect 为零/明显非法 → 该 client（bundleId）**最近一次合法 rect** 缓存。
  3. 仍无 → 前台窗口底部居中（P4 再精化）。**禁止**默认屏幕角落。
- 交互：鼠标点候选 → `select_candidate_on_current_page` → 正常 commit drain（**不许**直接 insertText 绕过控制器）。数字/减号/等号/空格/回车**一律进 Rime**，让用户 has_menu 翻页与选重绑定生效。
- 方案选单（switcher）就是一页候选——本窗即渲染载体，无需特殊逻辑。
- 缓冲模式默认把同一个带 `FocusToken` 的 panel 锚定在 44pt 折叠缓冲条下方；工具层向上展开到 78pt 时底边不动，因此候选不跳位。用户可在设置中切回 caret。两种位置共享完全相同的视觉、矩阵翻页、单字选择与提交状态，过期点击无效；工作台不再维护候选投影视图。

### 5.6 ChordController（并击）— 状态：✅ 已实现

- 机制（Squirrel 同款，原型验证过）：chording 键（a–z , .）按下且 Rime 已 handled → 入重放缓冲 + 重置定时器；到期把缓冲键全部以 `mask | releaseMask(1<<30)` 重放 → chord_composer 判定成 chord → drain commit。
- **门控**：仅 `schemaId == "my_combo"`。串击/双拼绝不注入合成 release（会扰乱 speller 时序）。
- **duration 的唯一来源**：`ChordSettings.duration`（UserDefaults `chord.duration`），默认 0.10s、范围 0.02–0.50s；设置变化通过通知实时更新所有 controller。
- flush 时机：非 chord 键按下前 / `deactivateServer` / `commitComposition` 前 / FocusObserver 触发。flush 期间**强持有** client 引用。

### 5.7 StatusMenu — 状态：✅ 系统输入法菜单单入口

只使用 macOS 已有的输入法专属位置，不再创建独立 `NSStatusItem`。`RimeBufferController.menu()`
每次打开系统输入法菜单时返回最新 `NSMenu`；设置、更新检查、日志、重新部署、重新安装与重启
均放在这里，引擎异常则在菜单顶部显示禁用的警告行。

InputMethodKit 会把菜单命令经 `doCommandBySelector:commandDictionary:` 发回当前
`IMKInputController`，因此每个条目的 target/action 必须落在当前 `RimeBufferController`，再转发给
`StatusMenu` 的共享操作。不要把 action 只挂到菜单单例上——旧实现曾因此出现菜单可见但动作在部分
macOS 版本不可靠。`Info.plist` 的 `etinput-menu.pdf` 继续负责系统输入法位置的图标。

方案切换只经 F4。Rime 内切换成功后把 schema id 记为 `preferredSchema`，各控制器激活时恢复该选择；设置页复选框只管理 F4 的 `schema_list`。

### 5.8 InputFocusCoordinator — 状态：✅ 已实现

为当前 controller/client 建立单调 `FocusToken` 租约，并同时校验租约 client 与 `controller.client()` 的对象身份、bundle id、前台应用 PID 与事件顺序。迟到的 deactivate、command、hide、候选点击或和弦 timer 只操作自己的 token；缓冲投递不存在 recent/last client 回退。NSWorkspace、锁屏/会话与输入源通知负责缺失生命周期回调时的最终撤销。同 proxy 切字段（跨 controller 也算）或旧 marked range 消失时建立新 epoch；旧 session 只在缓冲开启时回收到工作台，否则丢弃，绝不经已经指向新字段的 proxy 提交。弱 client 自然释放时也先清理仍存活 controller 的 chord/session，再移除租约。

### 5.9 Delivery — 状态：✅ 已实现

`Delivery.insert` 仍是唯一上屏咽喉。缓冲发送可由 Return 轻按/长按或主条右侧的纸飞机发起，但都必须交给 `BufferDeliveryCoordinator`。键盘路径固定使用 keyDown 时捕获的 `FocusToken`；协调器在每个块投递前重新校验 token、组字状态和 secure input。焦点变化立即停止，既不会改送新目标，也不会回送旧目标；未发送块保留。输入法自身窗口不是投递目标，也不参与远端镜像。

### 5.10 BufferWindowController + BufferModel（P2）— 状态：✅ 已实现

- 工作台是独立、nonactivating、可调整宽度的 `NSPanel`；只有 22pt 拖拽图标能移动窗口，背景和其他控件不能拖动。普通缓冲折叠/展开严格保持 44/78pt；苹果翻译与 AI 生成插件打开时主条改为上 source、下 target 两条独立横向滚动轨，折叠/展开为 78/112pt；拖拽与展开控件对齐上方源文行，发送控件对齐下方目标行。展开区固定为状态、缓冲插件选择器与当前动作、刷新/重置与关闭；选择器直接改写唯一 owner，刷新/重置保留缓冲正文并只重置当前插件运行状态。切换插件和展开状态始终固定底边与候选锚点。圆角表面使用日/夜固定 palette（不让透明 HUD 材质采样改变对比度），内缩到透明窗口边距，并按 backing scale 在路径内绘制 hairline。显隐、frame、展开态、pin 与候选锚点持久化，多屏变化时恢复到可见区域。普通关闭会收束组字、暂停捕获、结束 transient 加载/错误状态并保留已有块。`Command+Shift+B` 通过全局 Carbon hot key 调用 `openAndResume()`，因此既显示窗口也恢复缓冲捕获。工作台不提供块编辑器、面板内缓冲开关、手动遮蔽、历史恢复或清空撤销。
- Rime commit 只在捕获开启时进入 `BufferModel`；preedit 永不存入模型。成功调用 `Delivery.insert` 后，该 block 立即从 live buffer 消失且不保留明文发送历史；失败 block 和未发送后缀保留。
- 缓冲块在工作台中是被动展示单元，不再支持点选后单块编辑；Backspace 删除和显式投递仍由模型/协调器保持身份与顺序不变。输入法自身所有文本框都绕过缓冲捕获与远端镜像。
- 候选默认使用常规 `CandidateWindow` 固定显示在缓冲条下方，也可继续跟随 caret；工作台自身不含候选或全文预览。缓冲启停、常显与移屏入口保留在设置/输入法菜单；secure-input 检测与锁屏隐藏由 `BufferWindowController` 管理。锁屏、睡眠或会话切出会撤销租约、在 Rime 内收束组字并隐藏窗口，恢复后仍必须等新 activation/event。

### 5.11 AI 文本插件（P3）— 状态：✅ 三个缓冲插件已实现

- `AITextPluginWorkspace` 对当前 `BufferModel` 全文做显式生成快照；继续打字、切插件、关闭、secure input 或刷新都会取消/作废旧 generation。流式输出按逻辑 block index 原位更新并保持 UUID，不把 token 拆成 block；只有完成且仍匹配源快照的 target blocks 可投递。目标块全部成功发送后才一次性消费捕获的源 block，部分失败保留剩余目标与全部源文。
- `CodexCLITextProvider` 与 `ClaudeCodeCLITextProvider` 用 `Process`、固定 argv 和 stdin 在 0700 临时目录启动已登录 CLI，不经 shell，不把正文放入进程参数或日志，并限制时间与输出大小。“本地 CLI”只表示进程在本机启动，**不代表本地推理**；源正文会经 CLI 当前已登录的服务发送。
- `OpenAICompatibleTextProvider` 调用 `POST {baseURL}/chat/completions`，支持 SSE delta 和 JSON fallback。Base URL、model 与 API key 在“连接器 › AI 模型”管理；远程端点必须 HTTPS，HTTP 仅允许精确 loopback。配置与密钥存于 `~/Library/RimeBuffer/ai/openai-compatible.json` 的 0600 文件，不进 UserDefaults 或日志。
- 未经 review 的 Action Plugin 目标绑定块不能被 AI 插件当作源文，避免洗掉原 runtime/context/focus 权限。语音输入与通用提示词模板仍属后续能力。

### 5.12 Deploy / userdb（P4）— 状态：✅ 自包含部署已实现；学习词同步仍是路线图

- **现状**：app 自带 librime、插件和 Rime shared data，启动时在独立的 `~/Library/RimeBuffer` 执行 maintenance/deploy；正式安装不依赖 Squirrel。`build_install.sh` 默认可从 `~/Library/Rime` 重新播种用户配置与 userdb，也可在没有 Squirrel 用户目录时从 bundled schemas 独立部署。
- **隔离不变量**：两个活跃 Rime 实例不能共享同一 userdb LevelDB，因此运行时继续使用 `~/Library/RimeBuffer`，不直接打开 Squirrel 的 `~/Library/Rime`。
- **[P4 路线图]** 决定使用 librime sync 还是显式迁移来同步学习词，并完成 Developer ID 签名/公证；不得为了同步而恢复两个进程直接共用一个 userdb。

---

## 6. 关键契约备忘（实现时对照）

- **vtable 顺序 load-bearing**；`RIME_STRUCT_INIT` 每个 Rime 结构体必做（data_size 版本协商）。
- keysym：X11/ibus 体系。修饰 mask：shift 1<<0 / lock 1<<1 / ctrl 1<<2 / alt 1<<3 / super 1<<6 / **release 1<<30**。特殊键 0xff08(BS) 0xff09(Tab) 0xff0d(CR) 0xff1b(Esc) 0xff51–54(箭头) 0xff55/56(翻页) 0xffe1–ec(修饰) **0xffbe+n(Fn)**；可打印 0x20–0x7e 原码直传。
- 线程：IMK 键回调在主线程；P1 全部 librime 调用留主线程 + **watchdog**（单次 process_key/get_context >250ms 记日志定 Lua 嫌疑）。gMutex 不可重入。
- IMK 注册：bundle id=`com.isaac.inputmethod.RimeBuffer`，可选择 mode id=`com.isaac.inputmethod.RimeBuffer.Hans`（父/子 TIS id 必须不同），`InputMethodConnectionName=RimeBuffer_1_Connection`，`InputMethodServerControllerClass=RimeBufferController`（对应 `@objc(RimeBufferController)`）。父输入法不声明 repertoire，使 TIS 保持标准的 ASCII-capable parent；只有中文 child mode 声明 `Hans/Hant`，且不可含 `Latn`。底层键盘布局遵循 `squirrel.yaml`：`last`/空值不 override，`default` 才映射 ABC。重装/更新必须先选到 ABC 等 fallback，等旧 controller 正常 deactivate 后才能 kill/swap bundle；macOS 26 程序化切源漏发 deactivate 时，再由 TIS change notification 兜底收尾。IMKServer 引用存顶层变量保活；为 nil 时大声记日志退出，不留僵尸输入源。
- 日志 `~/rimebuffer.log`（IMELog）。**每个修复都要先能在日志里看见**（哪个键、哪个 client、走了哪条路径）——这是无 GUI 调试的生命线。

---

## 7. 仓库地图

```
rime-buffer/
├── ARCHITECTURE.md            ← 本文
├── Package.swift              ✅ CRimeBridge(C++17) + RimeBuffer(链 InputMethodKit/Cocoa)
├── Info.plist                 ✅ IMK 注册(连接名/控制器类/输入源 vending)
├── build_install.sh           ✅ 构建→ad-hoc 签名→装 ~/Library/Input Methods→lsregister→播种 userdb
├── Sources/CRimeBridge/
│   ├── include/CRimeBridge.h  ✅ C 接口 + BBRimeContext/BBRimeStatus 结构
│   └── CRimeBridge.cpp        ✅ vtable/dlopen/maintenance/deploy/健康门控/ConfigGetDouble
└── Sources/RimeBuffer/
    ├── main.swift             ✅ smoke 分支 + IMK 引导（不创建独立 StatusItem）
    ├── RimeEngine.swift       ✅ 可实例化封装
    ├── RimeKey.swift          ✅ keysym/mask 表（含 F1-F12、grave）
    ├── RimeModels.swift       ✅ RimeContextModel/RimeStatusModel
    ├── RimeBufferController.swift ✅ 总装完成(键路由/chord 门控/菜单/兜底/watchdog/forceCommit)
    ├── CandidateWindow.swift  ✅ 唯一候选面板+caret/缓冲条双锚点
    ├── InputFocusCoordinator.swift ✅ FocusToken+当前client租约
    ├── Delivery.swift         ✅
    ├── Log.swift              ✅
    ├── CompositionSession.swift  ✅ v2 组字协议(inline/placeholder)
    ├── ChordController.swift     ✅ duration 读 ChordSettings（默认 0.10s）
    ├── StatusMenu.swift          ✅ IMK menu() 单入口 + 菜单操作协调
    ├── (FocusObserver)           ✅ 以 main.swift 的 NSWorkspace 观察器实现(forceCommit+藏窗)
    ├── BufferModel.swift          ✅ P2 缓冲模型(live块/成功消费/无历史/transient)
    ├── BufferDeliveryCoordinator.swift ✅ 精确焦点逐块投递/失败后缀保留
    ├── BufferWindowController.swift ✅ 普通44/78pt、翻译双轨78/112pt/插件刷新/多屏/隐私
    ├── BufferInlineView.swift     ✅ 工作台块轨与来源徽标
    ├── GlobalHotKeyController.swift ✅ Command+Shift+B 全局打开并恢复工作台
    ├── AppleTranslationPlugin.swift ✅ 本地翻译双轨工作区
    ├── AITextPlugins.swift       ✅ Codex/Claude CLI + OpenAI 兼容 API 双轨生成工作区
    ├── SettingsWindow.swift       ✅ 四方案复选框/F4 列表/部署重启/候选窗与缓冲配置
    ├── InputSchemaCatalog.swift   ✅ 四方案产品目录 + schema_list 安全读写
    └── [P3+] 语音/CaretLocator/精细 Deploy

**键路由铁则补充(实测 bug 修正)**：Cmd 按住的 keyDown 一律直通 App(先 forceCommit 再放行)——
my_combo 里字母全是 chording key,不早退会被 chord_composer 吃掉 Cmd+C/V;
chord 缓冲排除一切带 Ctrl/Opt/Cmd 的键。
```

前身仓库（只读参考，不再开发）：`bufferbar-ime/`（IMK+桥原型，chord/flags 时序的行为规格）；`buffer-bar/`（独立 AX 注入 App，buffer UI 素材库）。

---

## 8. 构建 · 安装 · 调试手册

```bash
cd ~/Documents/05-dev/apps/rime-buffer
./build_install.sh                 # 构建+签名+安装+注册（幂等）
# 启用（一次性）：系统设置→键盘→输入法→编辑→＋→简体中文→RimeBuffer→添加
tail -f ~/rimebuffer.log           # 行为日志
.build/release/RimeBuffer smoke    # 四方案/F4/中文/英文引擎自检
.build/release/RimeBuffer schema-smoke  # 设置页 schema_list 读写自检
.build/release/RimeBuffer buffer-smoke # 成功消费/未发顺序/隐私丢弃/暂停保留
.build/release/RimeBuffer buffer-window-smoke # Focus/目标/生命周期门控/多屏frame
.build/release/RimeBuffer ai-text-smoke # CLI/API 解析、0600 配置与 source/target 投递自检
rm -rf ~/Library/RimeBuffer && ./build_install.sh   # 用户改了 Rime 配置后 reseed
pkill -x RimeBuffer                # 系统会按需重新拉起
# 卸载：rm -rf ~/Library/Input\ Methods/RimeBuffer.app && 输入源列表移除
```

已踩坑速查：签名用 ad-hoc（后台 shell 取不到自签身份私钥 `errSecInternalComponent`；trusted 身份留到 P4 公证）· 我方 Bash 沙盒里 `open` GUI app 会假失败，装完由系统拉起或用户双击 · smoke 若 0 候选先查四方案是否已部署以及 userdb LOCK。

---

## 9. 路线图与验收闸

### P1'（状态：**已全部实现并过三视角对抗审查（14 项修复已并入），等用户实测验收**）——"三个现场 bug 清零"

> 审查并入的关键修复：activateServer 用真实硬件修饰键状态播种 lastModifiers（Caps 常开不再乱流）；
> grave 按修饰键分派（Shift+`=波浪号 0x7e，Ctrl+grave=切换器）；deactivate/commit 只作用于当前
> `FocusToken`：显式 sender 必须精确匹配；nil/non-client sender 仅在 `self.client()` 仍指向同一对象且通过年龄/抑制规则时接受，绝不作为投递目标兜底；App 切换观察器升级为 forceCommit；候选点击加
> acceptsFirstMouse（非激活窗首击生效）；多屏定位改点包含（零宽 caret rect 与 intersects 不兼容）；
> 引擎恢复路径走 ensureSessionReady（chord 时长/方案门控不再半初始化）；F4 在 Rime 内切方案会
> 持久化为 preferred（与菜单切换同权）；chord flush 时序逐字节对齐原型（press 前 flush、release 不预 flush）。

| # | 任务 | 验收（用户实测） |
|---|---|---|
| 1 | CompositionSession：marked text 常驻（inline 默认 + placeholder per-app） | 微信打 zuoye→空格：**只出现「作业」，无字母残留**；组字串内联可见带下划线 |
| 2 | 候选窗定位链接入 marked 会话 caret rect | 候选窗贴在光标正下方，Safari/微信/终端一致；不再沉底 |
| 3 | RimeKey 补 F1–F12 + grave；确认 Ctrl+Shift+3 通路 | **F4 弹出方案选单**（候选窗渲染），可选到并击；Ctrl+Shift+3 切标点生效 |
| 4 | ChordController 抽出 + `ChordSettings` 可调 duration + my_combo 实测 | 并击单击不被吞、连击成词；其他方案无合成 release（日志验证） |
| 5 | StatusMenu（仅 IMK menu） | 无重复状态栏图标；系统输入法菜单可见且操作可用 |
| 6 | 兜底收口 + watchdog | kill -STOP 模拟引擎挂：打字退化英文不丢键；日志出现 watchdog 行 |

**P1 总闸**：用户以 RimeBuffer 为唯一输入法工作一整天（Squirrel 不卸载仅待命），四方案/F4/翻页/简繁/标点全程无需切回。

### P2 buffer / P3 语音+AI / P4 转正

闸口见 §5.10–§5.12。P2/P3 自动验收已覆盖成功消费且不留历史、未发顺序、迟到 focus epoch、多屏 frame、工作台插件单选、AI 流式 block 稳定性与双轨投递。真机还需覆盖 Safari/Electron/微信跨文本框切换、常显/全屏、`Command+Shift+B` 全局唤起、关闭保留、插件刷新不丢正文、翻译/AI 双轨控件对齐、真实 CLI/API 登录与 secure-input 遮蔽。P4 核心验收：连用一周零"打不出字"事件；改 schema 后进程内重部署生效；password 框优雅直通。

---

## 10. 风险登记簿（活文档，解决即划掉）

| 风险 | 缓解 |
|---|---|
| IME 进程崩/卡 = 系统级打不出字 | 兜底不变式(§3-3) + watchdog + Squirrel 待命 + 状态提示 |
| chord 时序被改坏 | 逐字节移植 + schema 门控 + duration 读配置 + 日志每键可追 |
| marked text 在个别敌意 App 仍坏 | per-app placeholder 模式表，逐个登记而非全局裸奔 |
| 每控制器 session 割裂全局开关体感 | activateServer 镜像 + UserDefaults 记忆 |
| userdb 双实例锁冲突 | 独立 ~/Library/RimeBuffer；转正后统一（§5.12） |
| Squirrel 升级/卸载破坏 dylib 依赖 | 启动路径校验 + 明示错误；P4 考虑自带 librime |
| Lua 脚本卡死输入线程 | watchdog 记录定位；用户改 Lua 先过 smoke |

## 11. 未决问题（留给用户/后续拍板）

1. 候选窗要不要横排模式跟随 `candidate_list_layout`？（用户现用 stacked 竖排，P1 只做竖排）
2. 学习词同步策略：P4 用 librime sync 还是直接回切 `~/Library/Rime`？
3. 转正时签名走 Developer ID 公证还是维持本地 trusted 自签？
