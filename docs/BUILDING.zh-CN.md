<!-- SPDX-License-Identifier: Apache-2.0 -->

# 从源码构建 Roammand

[English](BUILDING.md) · **简体中文**

本指南介绍运行、验证、构建和打包 Roammand 的受支持流程。

## 产品工作流

在仓库根目录运行 `make help` 可以查看常用命令。

| 目标 | 命令 |
| --- | --- |
| 检查工具并解析依赖 | `make bootstrap` |
| 分析和测试 Flutter App | `make app-check` |
| 构建 Debug Host 并运行 macOS App | `make app-run-macos` |
| 运行指定的 iOS 目标 | `make app-run-ios IOS_DEVICE=YOUR_IOS_DEVICE_ID` |
| 以生产性能运行 iOS | `make app-run-ios-release IOS_DEVICE=YOUR_IOS_DEVICE_ID` |
| 构建 macOS Release App | `make app-build-macos` |
| 构建 iOS 模拟器 App | `make app-build-ios-simulator` |
| 构建 Android Debug APK | `make app-build-android` |
| 构建并验证 macOS Host 安装包 | `make package-macos` |
| 创建 Developer ID 签名的 macOS `.pkg` | `make package-macos-signed` |
| 公证并 staple macOS `.pkg` | `make release-macos` |
| 运行完整产品门禁 | `make test-product` |

`make bootstrap`、`make app-check` 和 `make test-product` 会隐藏成功时的工具日志，最后只打印一行 `[PASS]` 结论。失败时会显示末尾 40 行日志、保留完整日志的路径，并给出查看完整输出的命令。需要实时查看每条命令时可添加 `VERBOSE=1`，例如 `make test-product VERBOSE=1`。

正常使用时，请在“网络服务”中选择 signaling 与 STUN，并可随时恢复内置官方配置。构建参数仍可作为开发和 CI 默认值，通过 `FLUTTER_ARGS` 传入：

```bash
make app-run-macos \
  FLUTTER_ARGS='--dart-define=ROAMMAND_SIGNALING_ENDPOINT=wss://signal.example.com:8443/v1/connect --dart-define=ROAMMAND_STUN_URLS=stun:stun.example.com:3478'
```

## 必需工具

仓库固定了生成文件和自动化检查所使用的工具版本。

| 工具 | 版本 |
| --- | --- |
| Flutter | 3.44.0 |
| Go | 1.26.5 |
| Rust | 1.97.0 |
| Buf | 1.69.0 |

还需要安装 Git、Make、Protocol Buffers 和 ripgrep。桌面原生 WebRTC 需要 `curl`、`unzip` 以及对应平台的 C/C++ 工具链。

在 macOS 上安装 Xcode Command Line Tools 和 CocoaPods。在 Windows 上安装 Visual Studio 2022，并选择 **Desktop development with C++**，同时安装受支持的 Windows SDK、CMake、Ninja 和 Git for Windows。运行以下命令确认目标平台环境：

```bash
flutter doctor -v
make doctor
```

## 解析工作区依赖

在仓库根目录运行：

```bash
make bootstrap
```

该命令会检查固定版本的工具链，并解析 Flutter、Dart、Rust 和 Go 依赖；不会安装系统软件包或开发者凭据。

## 在本地运行 Roammand

### 推荐：使用官方服务

在 macOS 上只运行：

```bash
make app-run-macos
```

该目标会下载或复用校验过的 native WebRTC、增量构建 Debug Host Agent，并通过 `ROAMMAND_HOST_AGENT_EXECUTABLE` 让 GUI 托管该进程。官方 signaling 与 STUN 已内置，不需要本地服务终端。

如果已经配置本地 Apple Team，且钥匙串中存在匹配的 Apple Development 身份，该目标还会为 Debug Agent 添加稳定签名；如果只有一个可用的开发身份，即使 Team 不同也只将它用于本地 Debug 二进制并打印警告，正式分发签名不受影响。第一次运行新签名时在钥匙串提示中选择“始终允许”；后续使用同一身份重新构建 Agent 时不应再次提示。没有开发签名身份时，macOS 仍可能在每次临时签名变化后询问。

若使用手机作为 Controller，第二个终端运行：

```bash
cd apps/client_flutter
flutter devices
flutter run -d YOUR_IOS_DEVICE_ID --no-pub
# Android：flutter run -d YOUR_ANDROID_DEVICE_ID --no-pub
```

`-d` 必须接收 `flutter devices` 返回的准确 ID。选择真机时不要传平台名称
`ios` 或 `android`。在仓库根目录运行 iOS 的等价命令是
`make app-run-ios IOS_DEVICE=YOUR_IOS_DEVICE_ID`。

常规运行是用于热重载的 Debug 构建，不能代表正式性能。请在实体设备上使用
`make app-run-ios-release IOS_DEVICE=YOUR_IOS_DEVICE_ID`
验证键盘、动画和帧耗时。

该路径只需要桌面与移动 App 进程，不需要额外启动本地 signaling 终端。安装后的
桌面与移动 Release 都直接从图形界面启动，不需要终端。依赖文件改变后重新运行
`make bootstrap`；平时的运行目标会直接使用锁定并已缓存的依赖。

### 高级：启动本地 signaling

仅在同一台电脑上进行回环测试：

```bash
cd services/signaling
go run ./cmd/signaling
```

默认会话地址为 `ws://127.0.0.1:8080/v1/connect`。

信令服务默认最多接受 1,024 个并发 WebSocket 连接、每个来源 IP 64 个连接、
全局 4,096 个活动配对 rendezvous，并允许每台 Host 同时创建 4 个活动
rendezvous。运维人员可通过 `SIGNALING_MAX_CONNECTIONS`（1–65,536）、
`SIGNALING_MAX_CONNECTIONS_PER_IP`（1–65,536）、
`SIGNALING_MAX_RENDEZVOUS`（1–65,536）和
`SIGNALING_MAX_RENDEZVOUS_PER_HOST`（1–64）调整这些有界上限。请根据主机内存、
NAT 后的预期设备数量和流量显式设置，避免部署成无上限服务。
`SIGNALING_SHUTDOWN_TIMEOUT` 默认为 10 秒，必须大于零且不超过一分钟。

除 64 条的缓冲队列外，出站投递还有固定的字节预算：进程全局 64 MiB、每个来源
IP 4 MiB、每个连接 526,336 字节（两个最大尺寸的信令帧）。服务会在把帧复制到
队列之前同时预留这三层预算，并在帧写入套接字期间继续持有预算。这些内建安全
预算不能通过环境变量调大；无法取得预算的投递会被拒绝，避免慢消费者导致内存
无上限增长。

入站安全上限也是固定值：每个 1 秒窗口内，每连接 256 帧 / 32 MiB、每来源
IP 4,096 帧 / 128 MiB，进程全局 32,768 帧 / 512 MiB。应用帧与收到的 ping/pong
帧都会计入；超限会以状态码 1013 关闭 WebSocket。流量 IP 窗口映射最多 65,536 条。
配对创建与加入请求另外共享每来源 IP 每分钟 30 次的预算，加入请求每个 lookup key
最多 5 次；限流器映射最多保留 65,536 个 IP 与 262,144 个 lookup 条目。相关
映射已满时，新 key 会以 `PAIRING_RATE_LIMITED` 拒绝（fail closed）。

仅在源码 Debug 构建中，同一可信局域网内的实体 Controller 可以使用明文 WebSocket，无需安装开发证书。先让 signaling 监听所有网卡：

```bash
cd services/signaling
SIGNALING_LISTEN_ADDR=0.0.0.0:8080 go run ./cmd/signaling
```

使用 Host 电脑的私有地址，例如 `ws://192.168.3.168:8080/v1/connect`。该开关只接受 RFC 1918 IPv4 或 IPv6 ULA 字面量；域名和公网地址仍会被拒绝。所有参与的 Debug 组件都必须显式开启：

```bash
ROAMMAND_ALLOW_INSECURE_LAN_SIGNALING=true \
ROAMMAND_SIGNALING_ENDPOINT='ws://192.168.3.168:8080/v1/connect' \
cargo run -p roammand-host-agent --features native-webrtc -- serve
```

```bash
make app-run-macos \
  FLUTTER_ARGS='--dart-define=ROAMMAND_SIGNALING_ENDPOINT=ws://192.168.3.168:8080/v1/connect --dart-define=ROAMMAND_ALLOW_INSECURE_LAN_SIGNALING=true'
```

```bash
make app-run-ios IOS_DEVICE=YOUR_IOS_DEVICE_ID \
  FLUTTER_ARGS='--dart-define=ROAMMAND_ALLOW_INSECURE_LAN_SIGNALING=true'
```

Android 使用 `flutter run -d YOUR_ANDROID_DEVICE_ID` 并传入相同 Dart definition。iOS 首次连接时需要允许“本地网络”权限。Rust 环境开关只在启用 debug assertions 的构建中生效，Flutter 开关只在 `kDebugMode` 为 true 时生效；Profile、Release 和已打包 Host 会忽略开关，并继续拒绝非回环 `ws://`。使用明文私有局域网端点创建的 Host 绑定只用于开发；测试 Profile 或 Release App 前必须通过 WSS 重新配对。

常规跨设备使用和所有 Release 验收必须使用 WSS，并使用所有设备都信任的证书：

```bash
cd services/signaling
SIGNALING_LISTEN_ADDR=0.0.0.0:8443 \
SIGNALING_TLS_CERT_FILE='certs/fullchain.pem' \
SIGNALING_TLS_KEY_FILE='certs/private-key.pem' \
go run ./cmd/signaling
```

将 `wss://<server-name>:8443/v1/connect` 作为连接地址。反向代理必须保留二进制 WebSocket 帧和 `roammand-signaling.v1.protobuf` 子协议。

### 高级：独立启动 Host Agent

在被控制的电脑上运行：

```bash
ROAMMAND_SIGNALING_ENDPOINT='wss://signal.example.com:8443/v1/connect' \
cargo run -p roammand-host-agent --features native-webrtc -- serve
```

Windows PowerShell：

```powershell
$env:ROAMMAND_SIGNALING_ENDPOINT = 'wss://signal.example.com:8443/v1/connect'
cargo run -p roammand-host-agent --features native-webrtc -- serve
```

Host Agent 管理桌面设备身份、授权记录、WebRTC peer、画面采集和输入链路。在 macOS 上，请先打开“这台电脑”，按照检查项完成“屏幕录制”和“辅助功能”授权，再从其他设备连接。权限设置必须由本机用户主动发起，建立远程连接时不会弹出权限请求。这种独立模式用于底层开发；标准的 `make app-run-macos` 已由 GUI 托管 Agent。

### 高级：单独启动 App

macOS：

```bash
make app-run-macos \
  FLUTTER_ARGS='--dart-define=ROAMMAND_SIGNALING_ENDPOINT=wss://signal.example.com:8443/v1/connect'
```

Windows：

```powershell
cd apps\client_flutter
flutter run -d windows --dart-define=ROAMMAND_SIGNALING_ENDPOINT=wss://signal.example.com:8443/v1/connect
```

Flutter App 和 Host Agent 必须由同一操作系统用户运行。App 通过仅限当前用户且经过认证的 IPC 连接 Agent。GUI 会启动并停止自己托管的 Agent；如果它连接到开发者预先启动的 Agent，则不会取得所有权或在退出时停止它。

### 配对 Controller

- 手机或平板：在 Host 上打开“此电脑”，显示手机二维码，然后使用 `flutter devices` 返回的 ID 运行 `flutter run -d YOUR_DEVICE_ID`，再使用相机扫描。
- 另一台电脑：创建桌面配对码，在“我的电脑”中输入，核对全部四个英文验证词，并在 Host 旁确认批准。

批准后，已保存的电脑卡片可以直接发起后续会话，无需再次配对。在 Controller 上删除卡片只会删除本地记录；在 Host 上撤销授权才会阻止后续连接。

## STUN 配置

Release 配置使用 STUN 进行 ICE 直连，不提供 TURN 兜底。Host 和 Controller 应配置相同的公网 STUN 服务。独立运行的 Host Agent 从环境变量读取两个端点：

```bash
ROAMMAND_SIGNALING_ENDPOINT='wss://signal.example.com:8443/v1/connect' \
ROAMMAND_STUN_URLS='stun:stun.example.com:3478' \
cargo run -p roammand-host-agent --features native-webrtc -- serve
```

安装版 GUI 会把“网络服务”中选定的配置传给自己管理的 Agent。Flutter 开发构建可以使用 `--dart-define=ROAMMAND_STUN_URLS=stun:stun.example.com:3478` 覆盖默认 STUN 服务。

按照 [Docker Compose 自托管](self-hosting/docker-compose.zh-CN.md)可以部署匹配的 WSS 信令与 UDP STUN。没有 TURN 时，部分对称 NAT、企业网络和蜂窝网络会连接失败，而不会自动转发流量。

### 可选的底层 TURN 测试

Peer 底层仍保留 TURN 环境变量，供开发者独立测试，但 Release 配置和默认 Compose 不会暴露 TURN。测试仅中继连接时，请在两端配置相同的短期参数：

```bash
ROAMMAND_ICE_TRANSPORT_POLICY=relay \
ROAMMAND_TURN_URLS='turns:turn.example.com:5349' \
ROAMMAND_TURN_USERNAME='<short-lived-username>' \
ROAMMAND_TURN_PASSWORD='<short-lived-password>' \
ROAMMAND_SIGNALING_ENDPOINT='wss://signal.example.com:8443/v1/connect' \
cargo run -p roammand-host-agent --features native-webrtc -- serve
```

```bash
cd apps/client_flutter
flutter run -d YOUR_IOS_DEVICE_ID \
  --dart-define=ROAMMAND_ICE_TRANSPORT_POLICY=relay \
  --dart-define=ROAMMAND_TURN_URLS=turns:turn.example.com:5349 \
  --dart-define=ROAMMAND_TURN_USERNAME='<short-lived-username>' \
  --dart-define=ROAMMAND_TURN_PASSWORD='<short-lived-password>'
```

TURN URL、用户名和密码必须同时提供或同时省略。不要提交或记录这些凭据。该高级
路径需要开发者自行运维 TURN 服务，不属于 Roammand 当前官方配置提供的兜底能力。

## 构建平台 App

```bash
make app-build-macos
make app-build-ios-simulator
make app-build-android
```

Windows Release：

```powershell
cd apps\client_flutter
flutter build windows --release --no-pub
```

构建产物保存在 `apps/client_flutter/build/`，并由 Git 忽略。

### 检查 iOS 制品中的私有 API

每个 iOS 制品在分发前都必须扫描。扫描脚本支持 `.app`、`.xcarchive` 和 `.ipa`，
会遍历制品内的全部 Mach-O 文件，包括主可执行文件、嵌入式 Framework 和 App
Extension，并在原始二进制字节中查找被禁止的 ReplayKit selector
`buttonPressed:`：

```bash
./scripts/check_ios_private_api.sh apps/client_flutter/build/ios/iphonesimulator/Runner.app
./scripts/check_ios_private_api.sh apps/client_flutter/build/ios/archive/Runner.xcarchive
./scripts/check_ios_private_api.sh path/to/Roammand.ipa
```

如果命中 selector、制品格式无效或没有任何 Mach-O 文件，脚本都会以非零状态退出。
它不依赖 `otool` 输出的 Objective-C 元数据，因为该 selector 可能位于
`__TEXT.__cstring`。macOS CI 会在 iOS Simulator 构建完成后立即执行扫描。发行时，
必须在上传 App Store Connect 前分别扫描最终 Archive 和由该 Archive 导出的 IPA。

## 发布通道与版本规则

通过 GitHub Releases 发布的 macOS 安装包与通过 TestFlight/App Store 分发的
iOS App 是两条独立的发布线。两端的营销版本号和构建号不要求一致。每个平台应根据
实际包含的改动、该通道上一次已发布版本、分发要求和审核状态，独立决定版本号与
发布时间。

- 发布或标记 macOS GitHub Release，不得自动触发 iOS 发布，也不得仅为对齐版本号
  而升级、重新构建或上传 iOS App。
- iOS 提交、等待审核、被拒或重新提交，不得阻塞 macOS GitHub Release，也不得据此
  重编号 macOS 版本。
- 只有两端的发布范围和时间确实一致时，才可以主动采用相同版本号；版本一致不是
  发布要求。
- 每条发布记录都必须明确平台、通道、营销版本号、构建号和源码提交。仓库 tag 或
  macOS GitHub Release 不代表同版本 iOS 构建已经存在或已经发布。

`apps/client_flutter/pubspec.yaml` 中的版本只是 Flutter 工程的共享构建默认值，
不是跨发布通道锁定版本的规则。当前 macOS 打包流程会读取该默认值。创建 iOS
Archive 前，必须根据 App Store Connect 历史独立确定 iOS 营销版本号和构建号，
并显式传入两个值（执行前替换下列大写占位符）：

```bash
cd apps/client_flutter
flutter build ipa --release \
  --build-name=IOS_MARKETING_VERSION \
  --build-number=IOS_BUILD_NUMBER \
  --no-pub
```

上传前必须核对 Archive 中的 `CFBundleShortVersionString` 与 `CFBundleVersion`，
并按上文要求分别扫描 Archive 和导出的 IPA。
发布记录应写成 `macOS GitHub Release 1.4.0 (build 18)` 或 `iOS TestFlight
1.2.3 (build 27)` 等无歧义形式。App Store Connect 使用 Bundle ID 与版本号把构建
关联到版本记录，并使用构建字符串唯一识别该构建；参见 Apple 的
[构建上传说明](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)。

## 打包可安装的 Host

默认 Release 构建要求工作树干净。打包脚本只会暂存允许的 App、Agent、Bridge/Helper、服务定义、许可证、受保护卸载器和排序后的 SHA-256 清单。设备身份、授权、连接地址、凭据、私钥和本地开发者路径不会进入安装包。

打包允许列表和安装清单属于技术完整性检查，不能代替发布合规记录。macOS 流程会
根据实际暂存的 payload 以及锁定的 Cargo、Dart/pub、CocoaPods、Flutter 和原生
WebRTC 输入，另行生成 `SBOM.spdx.json`、`THIRD_PARTY_NOTICES.md` 与
`SOURCE_CODE.md`。遇到未知许可证、缺失声明、无效来源记录或缺少必需输入时，生成
过程会在替换发布文件前停止并阻止发布。打包门禁会校验完整的三文件集合，CI 还会
使用固定版本的 `spdx-tools` 0.8.5 校验生成的 SPDX 文档。其他独立分发的二进制、
容器、iOS 构建和托管服务仍须分别生成并审阅自己的制品级材料。范围见
[许可证说明](../LICENSES.md)。

### macOS

`make package-macos` 会构建 `arm64 + x86_64` Universal App 与后台组件，生成
macOS 合规记录，并暂存供开发验收的目录：

```bash
make package-macos
sudo ./scripts/install_m8_macos.sh --package dist/m8-macos --dry-run
sudo ./scripts/install_m8_macos.sh --package dist/m8-macos
```

官网正式分发使用签名 `.pkg`。安装 Developer ID Application 与 Developer ID Installer、配置本地 Apple Team 后，先运行安全预检：

```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin
./scripts/check_apple_release_preflight.sh
make package-macos-signed
```

该流程按 Frameworks、独立 Agent、嵌套 Session Agent、主 App 的顺序使用
Developer ID Application 与 Hardened Runtime 签名；随后重新生成合规记录与安装
清单，确保其中的哈希描述签名后的 payload，再使用 Developer ID Installer 创建
`dist/apple-release/Roammand.pkg`。合规记录默认使用实际 UTC 生成时间；只有受控
的可复现构建才应显式设置 `SOURCE_DATE_EPOCH`。该目标不会提交公证。

将公证凭据交互式保存到 Keychain，避免把 Apple ID、Team ID 或密码写进命令参数：

```bash
xcrun notarytool store-credentials roammand-notary
```

API 私钥路径提示留空，随后在本地输入 Apple ID、Team ID 与 App 专用密码。App 专用密码在 [Apple Account](https://account.apple.com/) 的“登录与安全”中创建。最后执行：

```bash
make release-macos
```

该目标使用 `roammand-notary` Keychain profile 提交 Apple notary service，等待 `Accepted`，staple 最终 `.pkg`，并执行 stapler 与 Gatekeeper 验证。原始身份和凭据不会打印；失败的公证日志只保存在被 Git 忽略的 `dist/apple-release/`。

安装器会把包含嵌套 Session Agent 的 `Roammand.app` 放入 `/Applications`，将 Host 与特权二进制放入 `/Library/PrivilegedHelperTools`，并将受保护会话的 launchd 定义放入 `/Library/LaunchDaemons` 和 `/Library/LaunchAgents`。安装器会立即把 Session Agent 加载到当前图形会话，无需注销或重新登录。打开 GUI 会启动已安装的 Host Agent；关闭窗口时 GUI 与 Agent 会继续在托盘运行，只有明确选择“退出”才会停止由该 GUI 启动的 Agent。

安装版会提供“**设置 → 高级 → 卸载 Roammand**”。该操作会请求管理员授权，停止已安装的服务，并完整移除 App、后台组件、本地数据和仅属于 Roammand 的系统授权。开发构建中的卸载入口保持禁用，避免误删另一份正式安装版本。

开发者仍可先独立运行 `roammand-host-agent serve` 再启动 GUI；GUI 会连接既有进程，不会取得其所有权，也不会在退出时停止它。设置 `ROAMMAND_HOST_AGENT_AUTOSTART=false` 可以关闭已安装 Agent 的自动启动回退，设置 `ROAMMAND_HOST_AGENT_EXECUTABLE` 可以指定用于测试的 Agent 二进制。

仓库脚本仍可作为终端兜底方式，也可先预览卸载操作：

```bash
sudo ./scripts/uninstall_m8_macos.sh --dry-run
sudo ./scripts/uninstall_m8_macos.sh
```

### Windows

使用管理员 PowerShell：

```powershell
pwsh -NoProfile -File scripts/package_m8_windows.ps1
pwsh -NoProfile -File scripts/check_m8_windows_package.ps1 -Package dist\m8-windows
pwsh -NoProfile -File scripts/install_m8_windows.ps1 -Package dist\m8-windows -WhatIf
pwsh -NoProfile -File scripts/install_m8_windows.ps1 -Package dist\m8-windows
```

预览或移除已安装组件：

```powershell
pwsh -NoProfile -File scripts/uninstall_m8_windows.ps1 -WhatIf
pwsh -NoProfile -File scripts/uninstall_m8_windows.ps1
```

macOS 卸载器会完整移除 Roammand 的设备身份、Controller 授权、已保存 Host、偏好设置、缓存，以及仅属于 Roammand 的屏幕录制和辅助功能授权。Windows 终端卸载器目前仍保留每位用户的设备身份和 Controller 授权。请使用[最终产品人工验收清单](operations/final-product-acceptance.md)在真实操作系统上验证受保护图形会话。

## 配置本地 Apple 签名

公开 Xcode 工程不包含 Apple 开发者身份。在仓库根目录配置由 Git 忽略的本地覆盖文件：

```bash
./scripts/configure_apple_signing.sh \
  --team-id YOUR_TEAM_ID \
  --bundle-id com.example.roammand
./scripts/configure_apple_signing.sh --check
```

该命令会校验输入，以原子方式写入 `apps/client_flutter/apple/Signing.local.xcconfig`，并将权限设置为 `0600`。证书、私钥、Provisioning Profile、App Store Connect `*.p8` Key 和本地 Export Options 必须始终保留在 Git 之外。

使用不会打印 Team ID、Bundle ID 或签名身份的预检确认 Release 配置：

```bash
./scripts/check_apple_release_preflight.sh
```

iOS 使用 App Store/TestFlight Archive 发行。完整 macOS Host 使用 Developer ID 签名、Hardened Runtime、签名安装器、公证和 stapling，通过官网下载发行。其需要特权组件且不使用沙盒的架构不适用于 Mac App Store；如需商店发行，必须采用独立的沙盒 Controller-only 设计。

在提交公开 iOS 版本前，必须发布稳定、可公开访问的隐私政策 URL，并在 App 内易于
找到的位置提供入口，以满足 [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
的要求。政策与 App Store 隐私申报必须同真实 App、官方 signaling/STUN 运营、
基础设施供应商和集成的第三方代码一致，包括数据用途、保留/删除与持续可用的
隐私联系渠道。官方服务运营方将政策发布在
<https://hclgame.com/roammand/privacy>，经核实的运营边界记录在
[官方基础设施配置](operations/official-infrastructure-plan.zh-CN.md)中。隐私政策和
App Store 申报都是发布前置；只要 App、服务部署、供应商或保留配置发生变化，就必须
重新核对。

## 验证改动

```bash
make format-check
make test
make test-product
```

生成并验证带版本的协议产物：

```bash
make generate
make generate-check
make test-conformance
```

协议、配对、会话、Bridge、安全、自托管和运维契约分别记录在[架构](architecture/README.zh-CN.md)、[安全](security/README.zh-CN.md)、[自托管](self-hosting/docker-compose.md)和[运维](operations/README.zh-CN.md)文档中。
