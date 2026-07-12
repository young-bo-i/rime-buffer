# Enter输入法 (ETInput)

从零做的现代 macOS 输入法：librime 引擎 + 自绘候选窗 + 常驻缓冲区（buffer），提供并击、自然码双拼、雾凇拼音和英文四个方案。**自包含**——librime 与 Rime 词库打包在 app 内，装一个就能用，无需单独安装 Squirrel。

> 仓库/内部代号仍是 **RimeBuffer**（SPM target、`Sources/RimeBuffer/`、控制器类）；对外产品名是 **Enter输入法 / ETInput**。

**接手开发者：先读 [ARCHITECTURE.md](ARCHITECTURE.md)**——交接版全局架构，含模块规格、关键契约、实测修正（v2：marked-text 会话常驻）、P1' 任务清单与验收标准。

## 安装

普通用户优先下载 GitHub Release 里的 `ETInput-版本号.pkg`，双击按向导安装。安装器会把
`ETInput.app` 放进 `/Library/Input Methods`，并在当前登录用户会话里自动注册、启用、尝试切换到
「Enter输入法」。

开发者本机调试再用脚本：

```bash
./build_install.sh                # 构建+安装到当前用户+注册
.build/release/RimeBuffer smoke   # 免安装引擎自检
.build/release/RimeBuffer schema-smoke  # 设置页方案列表读写自检
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
