# RimeBuffer

从零做的现代 macOS 输入法：librime 引擎（复用 Squirrel 的 dylib 与用户 `~/Library/Rime` 配置）+ 自绘候选窗 + 常驻缓冲区（buffer），支持并击（my_combo）。终点：替代 Squirrel 成为日常主力；过渡期 Squirrel 保持安装作兜底。

**接手开发者：先读 [ARCHITECTURE.md](ARCHITECTURE.md)**——交接版全局架构，含模块规格、关键契约、实测修正（v2：marked-text 会话常驻）、P1' 任务清单与验收标准。

```bash
./build_install.sh                # 构建+安装+注册
.build/release/RimeBuffer smoke   # 免安装引擎自检
tail -f ~/rimebuffer.log          # 行为日志
```
