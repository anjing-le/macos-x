# macos-x

安静的原生 macOS 工具箱。首个模块是 Windows 风格的窗口切换，目标是低延迟、低空闲占用，以及可以独立启停的功能。最低系统为 macOS 14。

## 工程边界

- Swift / AppKit 单进程；没有 WebView、账号、数据库、常驻录屏或插件市场。
- `Sources/MacOSX`：菜单栏入口、窗口切换模块、更新入口。
- `Sources/MacOSXCore`：不依赖 macOS 窗口服务的选择状态逻辑。
- `Resources`：应用元数据、OTA 公钥；私钥只在本机 Keychain。
- `scripts`：构建、签名更新包、准备发布。
- `tools`：本机进程采样。CI 和依赖版本均入仓。

第一版模块是内置 Swift 模块，支持运行时启停。先验证实际使用，再按第二个模块的需要提取共同接口；不预先建设动态插件 ABI、服务总线或多层依赖注入。

## 窗口切换

`⌥Tab` 向后选择，`⌥⇧Tab` 反向选择，松开 `⌥` 切换，`Esc` 取消；菜单栏也可打开面板。以具体窗口为单位，展示图标、标题和按需缩略图。

初始范围是当前桌面的可见普通窗口。最小化窗口、跨 Spaces、全屏和特殊应用不列为本版完整支持。焦点行为要在各目标应用上实测。

- 辅助功能权限：读取窗口和请求聚焦；从菜单栏打开授权入口。权限变更后可停用再启用模块。
- 屏幕录制权限：生成缩略图；未授权时仍可显示标题和图标。
- 必需的非公开窗口标识映射集中隔离；符号不存在或映射失败时不按标题猜测窗口。
- 不关闭 SIP，不向系统进程注入代码。

## 性能约束

以下是设计要求和待测目标，不能当作“最强性能”的结论：

- 快捷键回调只处理按键状态和缓存；不扫描窗口、不调用跨应用 AX、不截图。
- 慢应用的 AX IPC 放在后台，并设置超时；通过事件使缓存失效。
- 空闲时没有周期性窗口扫描、缩略图刷新或录屏流。
- 面板打开才生成缩略图；最多保留 12 张，关闭面板后丢弃迟到结果。
- 模块停用释放事件 tap、通知、后台任务、缓存和面板。
- 缓存已预热时，热键回调到面板提交显示的耗时目标为 p95 < 50 ms；这不等于屏幕实际呈现延迟。
- 首轮记录冷启动、空闲 CPU/RSS、打开/关闭面板后的资源变化；RSS 不是物理内存占用。

实际数字及证据在下方记录，未测项目保持未验证。

## OTA

仅使用一个稳定通道：[GitHub Releases](https://github.com/anjing-le/macos-x/releases)。唯一第三方运行时依赖是精确锁定的 Sparkle。

更新地址为 `https://github.com/anjing-le/macos-x/releases/latest/download/appcast.xml`。应用检查版本并由用户确认安装；不自动静默覆盖。更新档案必须通过内置 Ed25519 公钥校验，校验发生在解压前。错误配置或校验失败不能降级成未验证安装。更新源也要求签名；发布说明保存在 GitHub Release，应用内不加载远程 HTML。

更新签名和 Apple 代码签名/公证是不同机制。初始开发包使用本机 ad hoc 签名；这不代表已获 Developer ID 签名、公证或通过 Gatekeeper 分发验证。普通用户分发前需要完成这些独立步骤。

## 构建与验证

需要 Xcode 或对应 Swift 工具链。依赖由 Swift Package Manager 管理。

```sh
swift package --disable-keychain resolve
swift test
./scripts/build.sh
open dist/MacOSX.app
```

`Resources/update-public-key.txt` 是公开的更新验签公钥，可以提交。签名用私钥保存在 Keychain 的 Sparkle `macos-x` account；克隆代码不意味着拥有发布签名能力。开发/CI 可显式禁用更新；正常发布构建不能缺少公钥。

构建和发布脚本参数以各脚本的 `--help` 为准。发布前核对版本递增、来源 commit、档案签名、appcast 地址及包内容，再上传 GitHub Release。签名私钥不通过命令行字符串传递。

## 当前验证状态

- 仓库：`anjing-le/macos-x`，公开；本地 Git author/committer 已配置为 `anjing-le`。
- 本机环境：Apple Silicon，macOS 27.0.1，Swift 6.1.2。
- Release 构建、应用内嵌 framework/rpath、整包代码签名完整性检查、3 个选择状态回归测试：通过；最终编译没有警告。
- 本机应用进程启动并持续运行：通过；窗口切换、缩略图与热键交互尚未取得实机证据。
- 60 秒未操作面板的采样：RSS 均值约 37.1 MiB，峰值约 38.3 MiB；CPU 累计计时在采样精度下未测到增量。这只是未操作状态基线，不代表启用权限后的窗口切换性能。
- 应用包磁盘占用约 3.1 MiB，压缩档案约 1.0 MiB；当前仅为 Apple Silicon 构建。
- 独立签名测试：正确档案验签通过，翻转一位后被拒绝。正式 appcast 生成正在等待系统 Keychain 授权。
- GitHub CI、在线发布资源及真实 OTA 升级：待验证。
- Developer ID 签名、公证、多显示器、跨 Spaces 及完整回归：未验证。
