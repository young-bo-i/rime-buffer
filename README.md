# 恩特输入法 (ETInput)

从零做的现代 macOS 中文输入法：librime 引擎 + 自绘候选窗 + 常驻缓冲区（buffer），支持并击（my_combo）。**自包含**——librime 与 Rime 词库打包在 app 内，装一个就能用，无需单独安装 Squirrel。

> 仓库/内部代号仍是 **RimeBuffer**（SPM target、`Sources/RimeBuffer/`、控制器类）；对外产品名是 **恩特输入法 / ETInput**。

**接手开发者：先读 [ARCHITECTURE.md](ARCHITECTURE.md)**——交接版全局架构，含模块规格、关键契约、实测修正（v2：marked-text 会话常驻）、P1' 任务清单与验收标准。

```bash
./build_install.sh                # 构建+安装+注册
.build/release/RimeBuffer smoke   # 免安装引擎自检
tail -f ~/rimebuffer.log          # 行为日志
```

## 发布 / 自动更新

已装的恩特输入法会自动检查 GitHub Release 并在状态栏菜单提示一键更新。发布新版本：

```bash
./scripts/release.sh minor        # 打 tag 触发 CI 构建并发布 Release
```

细节见 [RELEASE.md](RELEASE.md)（CI、通用二进制、应用内更新流程）。
