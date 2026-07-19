# Enter输入法 (ETInput)

从零做的现代 macOS 输入法：librime 引擎 + 自绘候选窗 + 常驻缓冲区（buffer），提供飞耀互击、自然码双拼、全拼和英文方案。**自包含**——librime 与 Rime 词库打包在 app 内，装一个就能用，无需单独安装 Squirrel。

> 仓库/内部代号仍是 **RimeBuffer**（SPM target、`Sources/RimeBuffer/`、控制器类）；对外产品名是 **Enter输入法 / ETInput**。

**接手开发者：先读 [SYSTEM-ARCHITECTURE.md](SYSTEM-ARCHITECTURE.md)**——这是当前权威全局架构；[ARCHITECTURE.md](ARCHITECTURE.md) 保留 P1/P2 的历史契约与踩坑记录。

## 缓冲工作台

开启缓冲模式后，提交内容进入独立工作台。工作台折叠时是 44pt 高的单行细条，依次为拖拽图标、展开箭头、缓冲块轨和右侧发送；向上展开后总高 78pt，上层依次显示状态、缓冲插件选择器与当前插件动作、刷新/重置和关闭，底边与候选锚点保持不动。选择器可直接在工作台内切换所有 `.bufferAction` 插件，切换会自动启用新插件并替换唯一 owner。刷新/重置不清除缓冲正文：外部插件会取消过时任务并重新检测上下文，内置双轨插件会保留源文并重启当前生成。插件可用 `presentationId` 把多个场景动作收敛成一个稳定按钮：例如 Marine 始终只显示“生成评论”，宿主根据当前 `status.actionId` 在直评与回复逻辑间切换；没有有效评论框时按钮保留但禁用。只有拖拽图标能移动窗口；缓冲启停、常显与移到当前屏幕仍由设置或输入法菜单管理，工作台本身不再提供缓冲开关或块编辑器。按 `Command+Shift+B` 可在任意应用中全局打开工作台并恢复缓冲捕获。组字候选直接复用常规 `CandidateWindow` 的样式，显示在缓冲条下方。

缓冲模式下，普通或 Shift+Return 与 Backspace 都由输入法吞下，永不落到宿主文本框：若仍在组字/并击，本次 Return 只把它收束为缓冲块；没有未决组字时，轻按 Return 发送下一块，按住约 1.2 秒发送全部，条底部会显示按住进度。Backspace 只在精确焦点下编辑 Rime 组字或删除缓冲块。引擎故障但没有未决组字时，已有块仍可安全发送；若未决组字无法收束，或焦点不可信，本次按键只吞下、不投递。主条右侧纸飞机也是显式发送全部入口。Return 手势只认 keyDown 时绑定且当前仍有效的外部文本框；纸飞机只认点击时的当前实时焦点。切换应用或文本框后不会使用旧目标。成功发送的块会立即从缓冲条消失且不保存发送历史；发送失败或尚未发送的块继续保留。关闭工作台会暂停捕获、结束未完成的加载状态，但保留已有块；可选的跨应用隐私清理不可撤销，只在真实外部应用 A→B 时触发。

窗口位置和显示偏好会保存；缓冲内容只在本次输入法进程内保留。工作台不提供手动遮蔽、发送历史、恢复或清空撤销。

设置采用左侧一级导航、右侧横向子页：输入法（输入编码 / 键入模式 / 词库）、外观、缓冲区、连接器、插件和维护。词库页能通过 librime 官方用户词典接口导入/导出中文 `rime_ice` 与英文 `english` 的学习记录，不复制正在使用的 LevelDB；统计、打字测速和飞耀互击学习则作为可停用的内置扩展动态出现在左侧。

输入编码、键入模式和词库在设置中分层呈现，但运行时仍由经过验证的 Rime 方案组合承载，避免产生不能部署的任意交叉组合。当前包含全拼串击、自然码双拼串击、英文串击，以及复用同一飞耀码表的并击/互击：并击要求同一击左右半区都参与；互击还允许左侧声母、右侧韵母分别成击。

插件平台分为两类：外部缓冲插件与编译进应用的内置扩展。前者继续由 Action Plugin v1 宿主执行，可从本地目录、`manifest.json` 或 HTTPS 声明文件安装；安装、卸载和管理收进设置页顶部的独立弹窗，列表中的插件只保留一个 Switch。Marine 是首个兼容插件。后者可以贡献设置页和只读、脱敏的本地输入观测能力，但不能被外部包注入 AppKit 视图。两类插件使用带 domain 的身份隔离；仍匹配原上下文和焦点的外部结果进入缓冲区，失效或迟到结果进入收件箱待确认，两条路径都不会直接上屏。

「苹果本地翻译」是第一个内置缓冲插件（macOS 15+），与 Marine 等外部缓冲插件进入同一个列表、使用同一种卡片和唯一 Switch；打开新的插件会自动关闭旧 Switch 并切换唯一 owner。翻译工作台上方是合并为连续文本、不分 block 的原文缓冲，下方是独立且可分 block 的译文缓冲，两条轨道各自横向滚动。翻译态下，左侧拖拽与展开按钮直接对齐上方原文行，右侧发送按钮直接对齐下方目标语言行。输入停顿 300 ms 后发起刷新；持续输入时至多等待 900 ms 就启动一轮，翻译在途期间只排队最新快照，不反复取消。源语言默认中文并要求显式选择，目标语言可选。发送键只投递与当前原文完全匹配的已完成译文，永不自动上屏。

「Codex CLI」、「Claude Code CLI」和「OpenAI 兼容 API」是三个新的互斥内置缓冲插件。它们只在用户点击“生成”时读取当前缓冲全文：源文保留在上方轨道，流式结果在下方以稳定 block 原位更新，完成后才可手动发送。只有下方所有目标 block 都成功发送后，生成时捕获的源 block 才会一次性从上方消费；部分发送失败不会丢失源文。Codex/Claude 插件在本机直接启动已登录 CLI，但这不等于本地推理：缓冲正文会经各自 CLI 的已登录服务发送。Codex CLI 采用经过工具面回归的版本白名单，未知版本会拒绝处理正文，等待 RimeBuffer 更新兼容。OpenAI 兼容 API 插件在“设置 › 连接器 › AI 模型”配置 Base URL、model 和 API key；密钥与配置保存到 `~/Library/RimeBuffer/ai/openai-compatible.json`，文件权限为 0600，不写入 UserDefaults 或日志。

## 安装

普通用户优先下载 GitHub Release 里的 `ETInput-版本号.pkg`，双击按向导安装。安装器会把
`ETInput.app` 放进 `/Library/Input Methods`，并在当前登录用户会话里自动注册、启用、尝试切换到
「Enter输入法」。

开发者本机调试再用脚本：

```bash
./build_install.sh                # 构建+安装到当前用户+注册
.build/release/RimeBuffer smoke   # 免安装引擎自检
.build/release/RimeBuffer schema-smoke  # 设置页方案列表读写自检
.build/release/RimeBuffer buffer-window-smoke # 焦点/生命周期门控与多屏恢复自检
.build/release/RimeBuffer ai-text-smoke # CLI/API 解析、配置权限与双轨投递自检
tail -f ~/rimebuffer.log          # 行为日志
```

如果安装后输入菜单暂时没刷新，先运行 `killall TextInputMenuAgent SystemUIServer`，仍看不到再注销重登一次。

## 发布 / 自动更新

已装的 Enter输入法 会自动检查 GitHub Release；相关控制入口位于系统输入法菜单。发布新版本：

```bash
./scripts/release.sh minor        # 打 tag 触发 CI 构建并发布 Release
```

细节见 [RELEASE.md](RELEASE.md)（CI、通用二进制、应用内更新流程）。

## 隔空传字（Mac ↔ Mac）

从系统输入法菜单打开「设置…」并启用「隔空传字」，两台 Mac 即可把你打的字即时发到对方的输入框——加密的局域网
点对点直连（Network.framework + Bonjour + AWDL，无需同一 Wi-Fi、无需 Apple ID）。

配对是「请求 → 同意」，**没有配对码**：A 菜单点「配对新设备 → B」→ 两台各显示同一个 4 位验证码
→ A 核对后点「配对」、B 点「同意」→ 之后自动静默连接。基于 X25519 身份 + TOFU 信任，只有已
互相同意的设备能传字/收字（`RemoteTypingService`）。首次两台各弹一次「本地网络」授权。

## 已知问题

- **macOS 26 上，在微信窗口聚焦时切换输入法可能让微信崩溃**（崩在 Apple 的
  `TextInputUIMacHelper`／输入法切换 HUD，`*** CFRelease() called with NULL ***`）。
  这是 macOS／微信侧的上游问题，同样影响原生 Rime/Squirrel
  （[rime/squirrel#951](https://github.com/rime/squirrel/issues/951)）；Enter输入法在其他 App 均正常。
  **规避**：不要在微信窗口聚焦时切换输入法——先在别处切好输入法，再点进微信打字。
