<!-- SPDX-License-Identifier: Apache-2.0 -->

# 变更日志

[English](CHANGELOG.md) · **简体中文**

这里记录值得关注的用户体验、兼容性、安全、运维和打包变化。格式遵循
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，已发行版本遵循语义化
版本规则。

## [未发布]

### 变更

- 将 iOS 与 iPadOS 最低部署版本从 13.0 提升至 15.0，以满足 App Store Connect
  自 2027 年春季起执行的兼容性要求。

### 修复

- 串行执行二维码扫描器的生命周期命令；如果相机权限请求在 iOS App 进入后台后才
  完成，会立即暂停扫描，也不会被过期的前台事件错误恢复。
- 将托管的 `flutter_webrtc` 替换为仓库内可复现的 1.5.2 下游补丁，移除 iOS 与
  macOS 构建中未使用的 ReplayKit 私有 selector，并增加发行扫描器，在分发前拒绝
  仍包含该 selector 的 iOS 制品。

## [1.0.2] - 2026-07-21

### 新增

- 为 Rust、Go、Dart/Flutter、容器和 GitHub Actions 增加每周依赖更新，并在
  Pull Request 中执行依赖审查。
- 增加中英文变更日志，并完善贡献、安全、架构、运维、构建、自托管和用户文档。

### 变更

- 在适用的进程、来源地址、Host、lookup 和连接层级，对 signaling 连接数、
  rendezvous 数、入站流量、配对限流状态、队列条目和出站字节增加有界限制。
- Host、配对和 Controller 会话链路的 heartbeat 同时只允许一个等待严格关联的
  确认；客户端连接/关闭工作和 Host WebSocket I/O 均有时间边界。
- macOS 权限刷新改为有界退避流程，并加强已安装包完整性检查。
- 通过强制 Pub lockfile、Cargo locked 模式、Go module 只读模式和 clean-tree
  检查，使 CI 的依赖解析可复现。

### 安全

- 将第三方 CI Action 与容器基础镜像固定到不可变 commit/digest，并把 Docker
  构建上下文限制为镜像实际需要的两个 Go 源码目录。
- 为 signaling 增加固定的入站流量与内存状态预算、有界关闭和 WebSocket 操作、
  更严格的可信代理解析，以及 TLS 1.2 最低版本。
- 加强本地缓存和导出：限制字节数、处理损坏记录、拒绝符号链接、独占目标文件、
  清零秘密，并显式排除 Android 云备份与设备迁移。

### 修复

- 关闭已过期的异步 IPC、配对、signaling、renderer、DataChannel 和 peer 工作，
  避免其所属对象释放后继续发布状态。
- 在 Answer/Candidate 竞态中保留经过认证的 ICE 恢复；单项原生清理失败时仍继续
  执行其余关闭步骤。
- 移动控制进入后台后关闭会话，恢复前台后返回上一页面，并遮挡 iOS 任务切换器
  快照。
- 提升移动控制栏锁定、安全区域布局和键盘收起的稳定性。
- 将尚未公开的 iOS App Store 链接替换为源码构建指南，并修正 App 内“关于”页面的
  二维码配对说明。
- 防止并发导出诊断报告时选择并覆盖同一个目标文件。
- 在高频配对 relay 流量下仍保留合法 heartbeat 确认的严格关联，避免待确认请求被
  有界历史记录淘汰。

1.0.2 已取代 1.0.1。公开 macOS 制品是适用于 macOS 14.4 或更高版本、经过
Developer ID 签名、Apple 公证并附加公证票据的安装包。

## [1.0.1] - 2026-07-19

### 新增

- 增加 App 内项目说明、安装步骤和配套设备引导。
- 增加控制栏锁定模式，提供更沉浸的移动远程画面。

### 变更

- 持久化 Archive 发行所需的 iOS 出口合规声明。
- 优化 macOS 配套设备设置与“设置”页面表现。

### 修复

- 保持 macOS 受保护会话控制指示器不抢占焦点，并提高本机“停止”交互可靠性。
- 修正“设置”悬停区域形状并移除多余菜单提示。

1.0.1 已取代 1.0.0。公开制品是适用于 macOS 14.4 或更高版本、经过 Developer
ID 签名、Apple 公证并附加公证票据的安装包。

## [1.0.0] - 2026-07-19

### 新增

- 首个公开源码版本：无需账号的二维码/桌面码配对、Host 本机批准和持久化单向授权。
- 经过认证的 WebRTC 画面/控制会话、有界恢复、本机停止、授权撤销和隐私安全诊断。
- Windows/macOS Host 与 Controller，以及 iOS/Android Controller 的源码实现。
- 可自托管的内存 signaling 与 STUN-only Docker Compose 配置。
- 经过签名、公证和 stapling 的 macOS 14.4+ 安装包。

该版本包含已知问题，仅保留用于版本历史。请勿安装，应使用 1.0.1 或更高版本。

[未发布]: https://github.com/MisakiHCL/roammand/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/MisakiHCL/roammand/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/MisakiHCL/roammand/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/MisakiHCL/roammand/releases/tag/v1.0.0
