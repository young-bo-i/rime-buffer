# RimeBuffer 全局架构（交接版 v2）

> 本文是唯一的架构交接文档。写给**接手实现的模型/工程师**：读完本文 + 本仓库代码，
> 即可在不依赖历史对话的前提下继续开发。
> v2 与 v1 设计（11-agent 工作流产物）的**最大差异**：真机实测证伪了
> "永不 setMarkedText" 的假设，组字协议全面改为 **marked-text 会话常驻**（§4）。
> 修改本文档时保持"先说做什么、再说为什么"的写法。

---

## 0. 一页速览

| 项 | 内容 |
|---|---|
| 定位 | 从零做的现代 macOS 输入法：**librime 引擎 + 自绘 UI + 常驻缓冲区(buffer)**，终点是替代 Squirrel 成为用户日常主力 |
| 仓库 | `~/Documents/05-dev/apps/rime-buffer`（SwiftPM：C++ 桥 target + Swift executable） |
| 进程模型 | **单进程**。IMK 输入法进程内：dlopen librime、键路由、候选窗、buffer、菜单。**禁止任何跨进程 IPC**（前身项目的 state.json 轮询是事故根源，已废除） |
| 引擎 | dlopen Squirrel 自带的 `librime.1.dylib` + lua/octagram/predict 插件；用户配置复用（见 §2） |
| 上屏 | 只经 `client.insertText`（IMK 一等公民通道，网页/Electron/原生通吃） |
| 已验证 | 引擎链路 smoke 通过（my_serial 打 nihao→9候选→上屏「你好」）；.app 可安装可注册可打中文 |
| 实测遗留 | 3 个现场 bug（§4），根因已定位，修复规格已写好（§9 P1'），**这是接手者的第一批任务** |
| 兜底 | Squirrel 保持安装不动，用户随时切回；引擎宕机时输入法自动退化为原生 latin 直通 |

---

## 1. 产品定位与目标

### 1.1 为什么做（动因链）

1. 用户原型 BufferBar（`~/Documents/05-dev/apps/buffer-bar`）用辅助功能(AX)/模拟粘贴向任意输入框注入文字 → **网页/Electron 输入框千奇百怪，AX 写入假成功、粘贴抢焦点失败**，逐 App 调试不可持续。
2. 用户使用 Rime **并击（chord，my_combo 方案）**，在"有钩子的输入框"（Electron/终端等）里组字会被打断——根因指向 Squirrel `inline_preedit: true` 依赖目标框的 marked-text 会话，而这些框处理 marked text 不可靠。
3. 结论：**要可靠地把字送进任意焦点框，必须自己就是输入法**（`insertText` 是唯一一等公民通道）；要保住 Rime 体验，就内嵌 librime + 用户既有配置。
4. 顺势升级：参照微信/豆包输入法的形态 = 引擎 + 富 UI + 服务。用户手里已有深度定制的顶级引擎（librime + 30+ Lua），缺的只是现代前端。**buffer（缓冲区）是本产品的差异化杀手锏**：输入法内部的一等暂存平台，未来挂 AI 改写/翻译、语音、模板、多目标投递。

### 1.2 目标（按优先级）

1. **P1 日常可打**：用户两个活跃方案（my_combo 并击 / my_serial 串击）在 Safari、Electron、终端全部正常；候选窗自绘；insertText 上屏；引擎宕机不砸打字。
2. **P2 buffer 平台**：提交文字可先落缓冲面板，编辑/暂存后再冲刷到目标框。
3. **P3 语音 + AI**：在 buffer 上做听写和 AI 变换。
4. **P4 转正**：进程内自部署（改配置不用开 Squirrel）、per-app 精调、签名公证、设为默认。

### 1.3 非目标

- 不覆盖 Rime 全生态——只需服务**这个用户的**方案与习惯（§2）。
- 不做旧 ai_box 方案（Rime Lua 内候选行缓冲，用户已放弃；本项目的 buffer 是原生 UI 层方案）。
- 不修改用户的 `~/Library/Rime`（只读复制）。

---

## 2. 用户环境画像（实现时的"合同"）

来源：`~/Library/Rime`（git 管理）。**以下每一条都是实测/实读得出，直接决定实现细节。**

| 项 | 值 | 对实现的约束 |
|---|---|---|
| 活跃方案 | `my_combo`（并击，chord_composer）+ `my_serial`（串击，顺序输入） | chord 子系统**只对 my_combo 生效**（schema_id 门控） |
| 默认方案 | my_combo | 状态菜单需显示并可切换 |
| `page_size` | **9**（default.custom.yaml patch；default.yaml 原值 5） | 候选窗渲染 `menu.page_size` 行，**不许硬编码** |
| `chord_duration` | **0.05s**（squirrel.custom.yaml，用户特调"减少单击被吞"） | chord 重放定时器**从部署后的 squirrel 配置读**，不许硬编码 0.10 |
| 方案切换热键 | **F4 / Control+grave / Control+Shift+grave**（default.yaml switcher） | 键位表必须映射 F 键与 grave；切换器以**候选形式**渲染（就是一页候选），候选窗必须能正确显示它 |
| 标点切换 | Control+Shift+3 / Control+Shift+numbersign 绑定 ascii_punct | **修饰键组合必须先喂 Rime**，不许一刀切丢弃 |
| ascii 开关 | Shift_L=commit_code、good_old_caps_lock: true | flagsChanged 按下/抬起事件流的时序**逐字节保持原型行为** |
| 外观 | stacked 竖排、font_point 20、label_font_point 14、purity_of_form_custom 配色、inline_preedit: true | 候选窗视觉对齐目标；组字默认**内联**（marked text 显示 preedit） |
| Lua | 30+ 脚本（含 mode_switch、autocap、长词过滤等） | 引擎必须带 lua 模块；Lua 卡死是已知"打不出字"向量（→watchdog） |
| Squirrel | `/Library/Input Methods/Squirrel.app`，保持安装 | 它是 librime dylib 的来源 + 用户的兜底输入法，**转正前不许卸载** |

---

## 3. 三条铁律（违反即架构事故）

1. **单进程，零 IPC。** 候选窗、buffer、菜单全部在 IME 进程内自绘。前身项目把候选 UI 拆到另一进程、经 `~/Library/Rime/tmp/.../state.json` 轮询同步，造成"UI 进程没起来→打不出字"的脆弱链——**此模式永久禁止**。
2. **C 桥是 ground truth，逐字复用。** `Sources/CRimeBridge/CRimeBridge.cpp` 的 RimeApi vtable 是对着用户机器上 librime 1.16.0 实测通过的，**字段顺序 load-bearing**（声明顺序=内存布局，动一行就静默错位）。改桥只允许"追加包装函数"，不允许重排/删减 vtable。
3. **上屏唯一出口 + 永活兜底。** 所有文字（普通提交/chord 提交/裸兜底）只经 `Delivery.insert`（`client.insertText`）。任何按键路径在"引擎不健康或 session==0"时必须落到裸 insertText（可打印字符直通、Return→`\n`），**不存在"返回 false 且丢掉一个可打印字符"的路径**。引擎宕机 ≠ 打不出字，等于退化为英文键盘 + 状态提示"切回 Squirrel"。

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
┌─ RimeBuffer.app (IMK 输入法进程, LSBackgroundOnly + .accessory) ─────────────┐
│                                                                              │
│  main.swift ── IMKServer 引导 · 引擎预热 · 菜单/StatusItem 安装               │
│                                                                              │
│  RimeBufferController (IMKInputController, 每个客户端一个实例)                │
│    │  键路由: keysym 映射 → processRimeKey → commit drain → UI 更新           │
│    ├─ CompositionSession   ★v2 组字协议(marked text 常驻, inline/placeholder) │
│    ├─ ChordController      并击重放(仅 my_combo; duration 读配置=0.05s)       │
│    ├─ CandidateWindow      自绘候选窗(NSPanel, 定位链见 §5.5)                 │
│    ├─ StatusMenu           IMK menu() + NSStatusItem(方案切换/健康/重载)      │
│    ├─ FocusObserver        失焦强制 flush chord + 提交/清组字                 │
│    └─ Delivery             唯一上屏出口 insertText                            │
│                                                                              │
│  RimeEngine (可实例化封装, 每控制器独立 session) ── CRimeBridge (C++, dlopen) │
│    └─ librime.1.dylib + lua/octagram/predict  ←  /Library/Input Methods/Squirrel.app │
│    └─ 用户目录: ~/Library/RimeBuffer (自 ~/Library/Rime 播种的独立副本)        │
│                                                                              │
│  [P2] BufferSurface + BufferModel   [P3] AIOps(语音/AI)   [P4] Deploy/自部署  │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 5.1 CRimeBridge（C++，`Sources/CRimeBridge/`）— 状态：✅ 已改造并验证

- 职责：dlopen 4 个 dylib（RTLD_NOW|RTLD_GLOBAL，路径硬编码 Squirrel 位置）→ `rime_get_api` → `setup()+initialize()`（**不做** maintenance/deploy，吃 Squirrel 已部署的 `build/`）→ smoke session 健康门控。
- 已提供：`BBRimeStart/IsHealthy/CreateSession/DestroySession/ProcessKey/CommitComposition/ClearComposition/SelectCandidateOnCurrentPage/GetOption/SetOption/SelectSchema/Deploy/GetContext/GetStatus/CopyCommit/CopySchema/CopyLastError/FreeString`。
- `BBRimeGetContext` 语义：填**当前页**（librime 的 menu.candidates 本来就是按页数组）——preedit/光标、page_size/page_no/is_last_page、高亮下标、候选 text/comment/label（label 优先 select_labels，退 select_keys，再退序号）。字符串指针由桥的静态后备存储持有，**仅在下一次调用前有效**，Swift 侧立即拷贝。
- 所有权契约：C 侧 malloc → Swift `String(cString:)` → `BBRimeFreeString`。全部入口锁 `gMutex`。
- **P1' 需增补**：`BBRimeConfigGetDouble(configId, key, out)`（包 config_open/config_get_double/config_close），供读取部署后 squirrel 配置的 `chord_duration`（用户=0.05）。

### 5.2 RimeEngine（Swift）— 状态：✅ 已写

可实例化（**无单例、无共享 session**——前身的共享 session 会让组字状态跨输入框串扰）。`start()` 失败时保持可重试。用户目录默认 `~/Library/RimeBuffer`，环境变量 `RIMEBUFFER_USER_DIR` 可覆盖（CLI smoke 用）。

### 5.3 RimeBufferController — 状态：⚠️ 已写，需按 §4/§9 修

- **每控制器一个 session**：`activateServer` 建（懒）、`deactivateServer` flush+提交、`deinit` 先停 chord 定时器再销毁 session。
- **焦点进入时镜像全局开关**：读/写 ascii_mode、simplification、ascii_punct（等 UserDefaults 记忆值），让"简繁/中英"体感全局（Squirrel 是单 session 天然全局，我们要显式镜像）。
- **键路由规则**（顺序敏感）：
  1. `recognizedEvents` = keyDown | flagsChanged。
  2. keysym 映射表 = 原型 `RimeKey` 全表 **+ 增补**：F1–F12（X11 keysym `0xffbe + n`，F4 = `0xffc1`；Mac keyCode F4=118 等），grave（keyCode 50 → `0x60`），数字行/符号经 `event.characters` 直通已可用。
  3. **修饰键组合先喂 Rime**（带完整 mask 调 processKey）；Rime 未处理且 mask 含 command/control 时才 return false 放行给 App（Cmd-C 等正常）。**禁止**一刀切 `guard modifiers.isEmpty`。
  4. flagsChanged 的按下/抬起流与 caps 的 `mask ^ lockMask` 逻辑**逐字节保持原型**（Shift_L=commit_code、good_old_caps_lock 依赖精确时序）。
  5. 非 chord 键按下先 `flushChordRelease()` 再处理。
  6. 每次 processKey 后：drain commit → CompositionSession 更新 marked text → CandidateWindow 更新。
  7. 兜底不变式见 §3-3。
- `commitComposition(_:)`（IMK 回调）：flush chord → `commit_composition` → drain → 清 marked。

### 5.4 CompositionSession ★新模块（v2 核心）— 状态：❌ 待实现（P1' 第一优先）

- 状态机：`idle ⇄ composing`。composing 期间**每次上下文变化都刷新 marked text**；离开 composing（提交/取消/失焦）时结束会话。
- 内容策略（per-app 查表，默认 `inline`）：
  - `inline`：`NSAttributedString(preedit, 下划线)`，`selectionRange` 置于 `cursorPos`；
  - `placeholder`：全角空格 `"　"`。
- per-app 表：`bundleId → .inline | .placeholder`，UserDefaults 持久化，StatusMenu 可改；初始为空表（全 inline），实测哪个 App 坏加哪个。
- 提交路径：`Delivery.insert`（insertText 自动替换 marked 区）→ 若 Rime 仍在组字（长句剩余部分）→ 立刻 setMarkedText(新 preedit)；否则清会话。
- **切勿**在同一客户端同时"设 marked text"又"把 preedit 画在自己面板里重复显示"——inline 模式候选窗只画候选，placeholder 模式候选窗才画 preedit 行。

### 5.5 CandidateWindow — 状态：⚠️ 骨架已写，需修定位与视觉

- NSPanel（borderless + nonactivating，`.popUpMenu` 层级，canJoinAllSpaces + fullScreenAuxiliary + stationary，orderFrontRegardless）。宿主进程必须 `NSApp.setActivationPolicy(.accessory)`（纯 LSBackgroundOnly 应用不能可靠置窗，已在 main.swift 落实）。
- 渲染：`page_size` 行（用户=9）· label 用 librime select_labels · 高亮行 `highlightedIndex` · comment 淡色 · 翻页指示（page_no/is_last_page）· stacked 竖排 · 字号对齐用户（候选 20pt/标签 14pt）· 配色向 purity_of_form_custom 靠（P4 精调）。
- **定位链**（每次更新执行）：
  1. `client.attributes(forCharacterIndex: <marked 区 caret 下标>, lineHeightRectangle: &rect)`——有 marked 会话后这是可靠主路径（Squirrel 同款）；窗放 rect 下沿、必要时翻到上方防出屏。
  2. rect 为零/明显非法 → 该 client（bundleId）**最近一次合法 rect** 缓存。
  3. 仍无 → 前台窗口底部居中（P4 再精化）。**禁止**默认屏幕角落。
- 交互：鼠标点候选 → `select_candidate_on_current_page` → 正常 commit drain（**不许**直接 insertText 绕过控制器）。数字/减号/等号/空格/回车**一律进 Rime**，让用户 has_menu 翻页与选重绑定生效。
- 方案选单（switcher）就是一页候选——本窗即渲染载体，无需特殊逻辑。

### 5.6 ChordController（并击）— 状态：⚠️ 已写，需改 duration 读配置

- 机制（Squirrel 同款，原型验证过）：chording 键（a–z , .）按下且 Rime 已 handled → 入重放缓冲 + 重置定时器；到期把缓冲键全部以 `mask | releaseMask(1<<30)` 重放 → chord_composer 判定成 chord → drain commit。
- **门控**：仅 `schemaId == "my_combo"`。串击/双拼绝不注入合成 release（会扰乱 speller 时序）。
- **duration 从配置读**：`BBRimeConfigGetDouble("squirrel", "chord_duration")`，用户=0.05s；读不到才退 0.10。
- flush 时机：非 chord 键按下前 / `deactivateServer` / `commitComposition` 前 / FocusObserver 触发。flush 期间**强持有** client 引用。

### 5.7 StatusMenu ★新模块 — 状态：❌ 待实现（P1'）

用户明确要求"从状态栏或哪里进去的菜单"。双通道：

1. **IMK `menu()`**（主）：重写 `IMKInputController.menu()`——条目出现在系统输入法菜单（国旗/图标下拉，Squirrel 的"部署/同步"就在这）。条目：方案切换（并击 my_combo / 串击 my_serial，勾选当前）、简繁、中英、重载配置、打开日志、关于/健康状态。
2. **NSStatusItem**（辅）：常驻状态栏图标，镜像同一菜单 + 引擎健康 pill（"引擎异常—已退化英文，建议切回 Squirrel"）。IMK menu() 在个别系统版本抽风时用户仍有入口。

方案切换实现：`select_schema(session)` 立即生效 + UserDefaults 记 `preferredSchema`，各控制器 `activateServer` 时若当前 schema ≠ preferred 则切换（体感全局）。

### 5.8 FocusObserver — 状态：❌ 待实现（P1'，规模缩小）

v1 里它是"无 marked 模式"的救生员；v2 有 marked 会话后 IMK 的 `commitComposition/deactivateServer` 回调恢复可靠，本模块降级为**保险**：NSWorkspace App 切换通知 → flush chord + 提交组字 + 藏候选窗。全局 mouse-down monitor 仅在实测确有 App 漏回调时再加。

### 5.9 Delivery — 状态：✅ 已写

见 §3-3。P2 起"buffer 还是直达"的路由判断放在控制器 commit drain 这一个点，CandidateWindow/BufferModel 永不直接触 client。

### 5.10 BufferSurface + BufferModel（P2）— 状态：❌ 未开始

- BufferModel **从零写**：append-only 块列表，每次 Rime 提交/选候选 = 一块（自带 createdAt）。只继承旧 buffer-bar 的时序常量（块存活 3s、淡出 0.45s）。旧项目的 diff/切片/合并机器**不移植**（它存在只因当年系统输入法往 buffer 自己的 TextView 里组字，边界不可知；现在边界在插入时天然已知）。
- 提交拓扑=显式开关：buffer-OFF → P1 行为（直达焦点框）；buffer-ON → 提交**只进 buffer**（框内空着直到冲刷，文档明示这是预期），到期/手动冲刷经 Delivery 上屏。组字预览永远在候选窗，**组字不进 buffer**。`compositionActive` 标志在 processKey 前后由控制器设置，冲刷遇组字中则等待。
- BufferSurface：NSPanel（磨砂 chrome 可从旧 buffer-bar 移植），**被动显示**（canBecomeKey=false，绝不抢焦点；编辑是显式切换的模式）。

### 5.11 AIOps（P3）— 状态：❌ 未开始

语音（本地 SFSpeechRecognizer）与 AI 变换跑独立队列；**所有 librime 调用过 gMutex**（输入线程用 try_lock+短超时，宁可跳过一次 UI 刷新也不冻打字）；所有产出经 BufferModel → Delivery 单一入口。若用 librime 通知回调：C 蹦床里**立即拷贝消息 → dispatch 到 main**，绝不在回调线程碰 gApi 或 AppKit。

### 5.12 Deploy / userdb（P4）— 状态：策略已定，未实现

- **现状**：用户目录是 `~/Library/RimeBuffer`（`build_install.sh` 从 `~/Library/Rime` rsync 播种，排除 `sync/`）。动因：**两个 Rime 实例不能共享 userdb**——LevelDB 单写锁，Squirrel 活着时我们打不开（实测 `rime_ice.userdb LOCK` 直接导致 0 候选）。代价：学习词暂不互通；改配置后要 reseed（`rm -rf ~/Library/RimeBuffer` 再跑安装脚本）。
- **P4 转正方案**（用户日常只跑 RimeBuffer 后）：切回 `~/Library/Rime` 直用；或 librime sync 机制定期双向同步；自部署 = `BBRimeDeploy` 放非输入线程 + 部署完成通知驱动重载。启动时校验 dylib 路径存在（Squirrel 被卸载→明示"需要 Squirrel"而非静默英文化）、比对 schema 与 build 的 mtime 提示过期。

---

## 6. 关键契约备忘（实现时对照）

- **vtable 顺序 load-bearing**；`RIME_STRUCT_INIT` 每个 Rime 结构体必做（data_size 版本协商）。
- keysym：X11/ibus 体系。修饰 mask：shift 1<<0 / lock 1<<1 / ctrl 1<<2 / alt 1<<3 / super 1<<6 / **release 1<<30**。特殊键 0xff08(BS) 0xff09(Tab) 0xff0d(CR) 0xff1b(Esc) 0xff51–54(箭头) 0xff55/56(翻页) 0xffe1–ec(修饰) **0xffbe+n(Fn)**；可打印 0x20–0x7e 原码直传。
- 线程：IMK 键回调在主线程；P1 全部 librime 调用留主线程 + **watchdog**（单次 process_key/get_context >250ms 记日志定 Lua 嫌疑）。gMutex 不可重入。
- IMK 注册：Info.plist 的 `InputMethodConnectionName`（`RimeBuffer_1_Connection`，与旧原型区分）/ `InputMethodServerControllerClass=RimeBufferController`（对应 `@objc(RimeBufferController)`）/ `ComponentInputModeDict` 挂 `com.isaac.inputmethod.RimeBuffer`。IMKServer 引用存顶层变量保活；为 nil 时大声记日志退出，不留僵尸输入源。
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
│   └── CRimeBridge.cpp        ✅ vtable/dlopen/健康门控/结构体 API   ▶P1'加 ConfigGetDouble
└── Sources/RimeBuffer/
    ├── main.swift             ✅ smoke 分支 + IMK 引导            ▶P1'加 StatusMenu 安装
    ├── RimeEngine.swift       ✅ 可实例化封装
    ├── RimeKey.swift          ✅ keysym/mask 表                  ▶P1'补 F1-F12、grave
    ├── RimeModels.swift       ✅ RimeContextModel/RimeStatusModel
    ├── RimeBufferController.swift ✅ 总装完成(键路由/chord 门控/菜单/兜底/watchdog/forceCommit)
    ├── CandidateWindow.swift  ✅ 定位链+视觉参数+鼠标选字(acceptsFirstMouse)
    ├── Delivery.swift         ✅
    ├── Log.swift              ✅
    ├── CompositionSession.swift  ✅ v2 组字协议(inline/placeholder)
    ├── ChordController.swift     ✅ duration 读配置(用户 0.05s)
    ├── StatusMenu.swift          ✅ NSStatusItem + IMK menu() 双入口
    ├── (FocusObserver)           ✅ 以 main.swift 的 NSWorkspace 观察器实现(forceCommit+藏窗)
    ├── BufferModel.swift          ✅ P2 缓冲模型(append-only 块/3s 生命周期/组字暂停/顺序冲刷)
    ├── BufferSurface.swift        ✅ P2 底部暂存条(被动显示/块 chips/立即上屏/清空)
    ├── SettingsWindow.swift       ✅ 可视化设置 v1(方案列表/导入+自动进 schema_list/导出/部署重启/缓冲配置)
    └── [P3+] AIOps/CaretLocator/精细 Deploy

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
.build/release/RimeBuffer smoke    # 免安装引擎自检(打 nihao 应出 9 候选+上屏你好)
rm -rf ~/Library/RimeBuffer && ./build_install.sh   # 用户改了 Rime 配置后 reseed
pkill -x RimeBuffer                # 系统会按需重新拉起
# 卸载：rm -rf ~/Library/Input\ Methods/RimeBuffer.app && 输入源列表移除
```

已踩坑速查：签名用 ad-hoc（后台 shell 取不到自签身份私钥 `errSecInternalComponent`；trusted 身份留到 P4 公证）· 我方 Bash 沙盒里 `open` GUI app 会假失败，装完由系统拉起或用户双击 · smoke 若 0 候选先查 schema 是否 my_serial/my_combo（rime_ice 只是基座没独立部署）以及 userdb LOCK。

---

## 9. 路线图与验收闸

### P1'（状态：**已全部实现并过三视角对抗审查（14 项修复已并入），等用户实测验收**）——"三个现场 bug 清零"

> 审查并入的关键修复：activateServer 用真实硬件修饰键状态播种 lastModifiers（Caps 常开不再乱流）；
> grave 按修饰键分派（Shift+`=波浪号 0x7e，Ctrl+grave=切换器）；deactivate/commit 的 sender 兜底
> `?? self.client()`（防 marked text 残留）；App 切换观察器升级为 forceCommit；候选点击加
> acceptsFirstMouse（非激活窗首击生效）；多屏定位改点包含（零宽 caret rect 与 intersects 不兼容）；
> 引擎恢复路径走 ensureSessionReady（chord 时长/方案门控不再半初始化）；F4 在 Rime 内切方案会
> 持久化为 preferred（与菜单切换同权）；chord flush 时序逐字节对齐原型（press 前 flush、release 不预 flush）。

| # | 任务 | 验收（用户实测） |
|---|---|---|
| 1 | CompositionSession：marked text 常驻（inline 默认 + placeholder per-app） | 微信打 zuoye→空格：**只出现「作业」，无字母残留**；组字串内联可见带下划线 |
| 2 | 候选窗定位链接入 marked 会话 caret rect | 候选窗贴在光标正下方，Safari/微信/终端一致；不再沉底 |
| 3 | RimeKey 补 F1–F12 + grave；确认 Ctrl+Shift+3 通路 | **F4 弹出方案选单**（候选窗渲染），可选到并击；Ctrl+Shift+3 切标点生效 |
| 4 | ChordController 抽出 + duration 读配置(0.05s) + my_combo 实测 | 并击单击不被吞、连击成词；串击方案无合成 release（日志验证） |
| 5 | StatusMenu（IMK menu + NSStatusItem） | 菜单可见；点击切方案立即生效且跨 App 记忆 |
| 6 | 兜底收口 + watchdog | kill -STOP 模拟引擎挂：打字退化英文不丢键；日志出现 watchdog 行 |

**P1 总闸**：用户以 RimeBuffer 为唯一输入法工作一整天（Squirrel 不卸载仅待命），并击/串击/翻页/简繁/标点全程无需切回。

### P2 buffer / P3 语音+AI / P4 转正

闸口见 §5.10–§5.12。P2 核心验收：buffer-ON 时提交进面板可编辑、冲刷经 insertText 落原框、组字期间冲刷会等待；buffer-OFF 完全回到 P1 行为。P4 核心验收：连用一周零"打不出字"事件；改 schema 后进程内重部署生效；password 框优雅直通。

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
2. buffer 的呼出交互：常驻可见 or 热键唤起？（P2 开工前问用户）
3. 学习词同步策略：P4 用 librime sync 还是直接回切 `~/Library/Rime`？
4. 转正时签名走 Developer ID 公证还是维持本地 trusted 自签？
