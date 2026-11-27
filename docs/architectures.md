# macOS 的两套原生安装包

从 0.0.167 开始，同一版本分别编译 arm64（Apple Silicon，M 系列）和
x86_64（Intel）。不是给同一个二进制改名：主程序、图片/PDF 转换引擎、
Rust 文档引擎都必须是对应架构，嵌入的 Sparkle 组件必须包含该架构。
最低系统要求仍为 macOS 14。应用名称、标识、签名身份、用户数据和功能一致。

## 下载与 OTA

GitHub 发布页给出两个明确的 DMG 下载链接。“关于本机”显示 Apple M 系列
芯片选 Apple Silicon；显示 Intel 处理器选 Intel。官网此次不修改。

| 架构 | 首次安装 | OTA 包 | 签名更新源 |
|---|---|---|---|
| Apple Silicon | `macos-x-V-arm64.dmg` | `macos-x-V-arm64.zip` | `appcast.xml` |
| Intel | `macos-x-V-x86_64.dmg` | `macos-x-V-x86_64.zip` | `appcast-intel.xml` |

两个 ZIP、DMG 均附 SHA-256；两个 feed 各自 Ed25519 签名，指向自己的 ZIP。
`downloads.json` 记录实际文件名、大小、摘要及链接。原有 ARM 更新源 URL 不变，
旧版可直接升级到新命名的 ARM 包；Intel 使用独立更新源，不依靠一个未支持的
“Intel hardwareRequirements” 标签来猜测 Sparkle 的筛选行为。

首个 Intel 包没有既往已发布 Intel 基线，必须显式使用
`--initial-intel-release`：对真实上一版 ARM 包核对双向签名要求、应用标识、
公钥和递增构建号，仅允许固定 GitHub ARM feed 到固定 Intel feed 的一次性
新架构通道初始化。这不等于已完成 Intel OTA 安装实测。后续 Intel 更新必须
使用实际上一版 Intel 包，保持其更新源不变，不再传初始化参数。

## 构建与成对发布

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
scripts/build.sh --arch arm64 --output-dir dist/arm64 --sign-identity "$MACOSX_SIGN_IDENTITY"
scripts/build.sh --arch x86_64 --output-dir dist/x86_64 --sign-identity "$MACOSX_SIGN_IDENTITY"
MACOSX_PREVIOUS_ARM_APP=/实际上一版/ARM/MacOSX.app scripts/release-pair.sh \
  --initial-intel-release dist/arm64/MacOSX.app dist/x86_64/MacOSX.app dist/paired-release
```

后续成对发布同时设置 `MACOSX_PREVIOUS_INTEL_APP`，去掉初始化参数。
原生构建默认采用当前运行主机架构；交叉构建必须明确 `--arch`。文档引擎
使用对应 Rust target，不得把主机架构的 worker 混入另一个安装包。
开发/CI 可显式 `--disable-updates` 使用临时签名，但不能作为正式 OTA 上传。

## 验证边界

- `tools/verify-bundle-architecture.py` 检查真实 Mach-O，包括全部嵌套可执行文件，
  并核对架构声明。改文字或改名不能通过检查。
- `tools/architecture-distribution-regression.py` 会在临时副本中混入另一架构的
  真实 worker，验证必须拒绝；同时验证首个 Intel feed 例外的单向、固定边界。
- GitHub CI 分别使用原生 arm64 与原生 Intel runner，先断言 `uname -m`，
  再各自执行完整隔离功能回归、实际打包和 DMG 重复挂载/复制/签名验证。
- 成对发布再次核对两个版本及构建号、两个 feed、ZIP 签名和所有摘要。
  发布后还需读回公开资产字节、两个 latest feed 及 tag/CI 来源。

原生 CI 和交叉编译都是各自的证据；不能把 M 系列上的 Rosetta 执行称为
Intel 硬件运行，也不替用户安装应用、操作桌面或测试真实权限/菜单栏交互。
既有自签名与未做 Developer ID 公证的发行方式保持不变。
