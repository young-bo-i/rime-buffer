# 发布与自动更新

RimeBuffer 通过 **GitHub Actions + GitHub Releases + 应用内自动更新** 完成分发。

## 一、发布新版本

```bash
./scripts/release.sh minor     # 0.1.0 -> 0.2.0，或 patch / major / 指定 x.y.z
```

脚本会：同步/提交改动 → 更新 `Info.plist` 版本号 → 打 `vX.Y.Z` tag → 推到 GitHub（`origin`）。

推送 tag 会触发 [`.github/workflows/release.yml`](.github/workflows/release.yml)：

1. `swift build -c release --arch arm64 --arch x86_64`（**通用二进制**，Intel/Apple Silicon 通用）
2. 组装 `RimeBuffer.app`（拷贝二进制 + `Info.plist`，ad-hoc 签名，清除隔离属性）
3. `ditto` 打包为 `RimeBuffer-X.Y.Z.zip`
4. 创建 GitHub Release，附带 zip 与 SHA256

> librime 是在**运行时 `dlopen`** 复用 Squirrel 的 dylib（见 `CRimeBridge.cpp`），
> 因此 CI 构建无需安装 Squirrel，普通 runner 即可编译。

## 二、持续集成（CI）

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) 在每次 push / PR 到 `main` 时：
`swift build` + 运行 `buffer-smoke`、`stats-smoke` 两个纯 Swift 自检（不依赖 librime）。

## 三、应用内自动更新（[`UpdateManager.swift`](Sources/RimeBuffer/UpdateManager.swift)）

已安装并运行的 RimeBuffer：

- **启动时 + 每小时** 静默查询 `young-bo-i/rime-buffer` 的最新 Release；
- 版本更新（按 semver 逐段比较 `CFBundleShortVersionString`）时**后台静默下载** zip；
- 下载完成后，状态栏图标变色，菜单顶部出现「🎉 有新版本 vX — 立即更新」；
- 用户确认后：等待旧进程退出 → `pkill` 兜底 → 替换 `~/Library/Input Methods/RimeBuffer.app`
  → `xattr` 清除隔离 → **`lsregister -f` 重新注册**（输入法关键步骤）→ `open` 重启。
- 也可从菜单「检查更新…」手动触发。

安装过程日志：`~/rimebuffer-update.log`。自动检查默认开启（`UserDefaults` 键
`updateAutoCheckEnabled`）。

## 版本号约定

- `Info.plist` 的 `CFBundleShortVersionString` 用 `x.y.z`；tag 为 `vX.Y.Z`。
- CI 会用 tag 覆盖 plist 版本，用 `github.run_number` 作为 `CFBundleVersion`。
- 只有 tag 版本 **严格大于** 当前运行版本时，客户端才会提示更新。
