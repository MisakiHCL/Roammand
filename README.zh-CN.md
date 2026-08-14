<!-- SPDX-License-Identifier: Apache-2.0 -->

<p align="center">
  <img src="brand/roammand-app-icon.svg" width="112" alt="Roammand 标志">
</p>

<h1 align="center">Roammand</h1>

<p align="center"><strong>离开桌面，工作仍在继续。</strong></p>
<p align="center">无账号、隐私优先，安全控制你自己的电脑。</p>

[English](README.md) · **简体中文**

Roammand 把手机、平板或另一台电脑变成可信控制界面，让你随时操作承载工作的 Windows 和 macOS 电脑。设备之间直接配对，无需账号，以后可以直接重连。

从移动端继续桌面工作、掌握长时间任务，让个人计算环境始终触手可及。

## 平台支持与下载

当前源码已实现下表中的四个平台角色，但面向公众提供的通用安装包只有 macOS
版本。这里会明确区分源码目标与公开获取方式。

| 平台 | 角色 | 获取方式 |
| --- | --- | --- |
| macOS 14.4 或更高版本 | Host 与 Controller | [从 GitHub Releases 下载经过签名和公证的 `.pkg`](https://github.com/MisakiHCL/roammand/releases/latest/download/Roammand.pkg) |
| Windows 10 / 11 | Host 与 Controller | 提供源码构建与打包脚本；已安装 Host 的验收基线当前为 Windows 11；暂无公开安装包 |
| iOS / iPadOS 15 或更高版本 | Controller | 源码构建或维护者邀请测试；暂无公开 App Store 下载 |
| Android 7.0 或更高版本（API 24） | Controller | 源码构建；暂无公开安装包 |

macOS 历史安装包及资产摘要见
[GitHub Releases](https://github.com/MisakiHCL/roammand/releases)。在公开移动版
明确列于此处之前，源码构建和邀请测试版本仅用于开发与实体设备验证。

## 如何使用

1. 在作为 Host 的 Mac 上安装 Roammand，然后打开“**此电脑**”。控制端可以使用
   另一台已安装的 Mac、源码构建的 Controller 或受邀移动测试版本。
2. 按照 App 提示完成“屏幕录制”和“辅助功能”设置。两项权限就绪前，Host
   会保持不可用。
3. 手机或平板应扫描实时二维码邀请，再由 Mac 本机批准名称正确的 Controller；
   另一台电脑则输入一次性桌面配对码，核对全部四个英文验证词后由 Host 批准。
4. Mac 会出现在“**我的电脑**”中；以后选择“**连接**”即可继续远程工作。

安装、授权、配对、连接限制和卸载说明见[用户指南](docs/user-guide/README.zh-CN.md)。

## 你可以做什么

- 通过实时二维码邀请和 Host 本机批准来配对手机，或通过一次性代码与四词验证
  配对另一台电脑。
- 保存可信电脑，以后无需重新配对即可连接。
- 从 iOS、Android、Windows 或 macOS 控制 Windows 和 macOS。
- 在移动端使用触控手势、文本、修饰键和特殊键。
- 在短暂中断后通过有界、经过认证的流程恢复连接。
- 在 Host 上查看连接者、本机停止控制，并撤销任意 Controller。
- 导出隐私安全的诊断信息，并自托管 signaling 与 STUN 服务。

## 当前限制

- 一台 Host 同时只接受一个传入 Controller 会话，并共享主显示器；暂不支持选择
  多显示器。
- 不包含音频、剪贴板同步、文件传输、云同步或自动更新。
- 移动控制仅在前台运行。当前 iOS/iPadOS 界面只支持横屏，进入后台会关闭会话。
- 公开配置和随附自托管配置都没有 TURN 中继，严格网络中的 ICE 直连可能失败。
- 锁屏/登录界面控制需要安装版 Host 组件，并受操作系统权限与策略约束。不支持
  所有者首次登录前的冷启动访问、完全登出或 Host 退出后的持续控制，以及 FileVault
  预启动阶段。
- 官方 signaling/STUN 运营方已经发布[消费者隐私政策](https://hclgame.com/roammand/privacy)。
  如需自行控制基础设施、保留策略或政策，请使用自托管服务。

## 工作原理

Host 所有者核对并批准名称正确的 Controller 后，配对才会创建保存在 Host 本机的
单向授权。以后开始远程控制前，会话必须先验证这份已有授权；signaling 本身不能
授予访问权限。

授权始终是单向的：Controller 只能访问批准它的 Host。如果需要反向控制，必须重新配对并单独批准。

## 从源码开始

安装固定版本工具链和工作区依赖：

```bash
make bootstrap
make app-check
```

这些工作流会隐藏成功时的工具日志，最后只打印一行 `[PASS]` 结论；失败时会显示简短的错误末尾。需要查看完整过程时可添加 `VERBOSE=1`，例如 `make app-check VERBOSE=1`。

使用内置官方 signaling 与 STUN 时，只需启动桌面 App：

```bash
make app-run-macos
```

该命令会准备原生 WebRTC、增量构建 Debug Host Agent，并由桌面 GUI 启动和停止 Agent。测试手机 Controller 时，第二个终端只需运行对应的移动 App：

```bash
cd apps/client_flutter
flutter devices
flutter run -d YOUR_IOS_DEVICE_ID --no-pub
# Android：flutter run -d YOUR_ANDROID_DEVICE_ID --no-pub
```

`-d` 需要接收 `flutter devices` 列出的准确设备 ID；`ios` 和 `android`
是平台名称，不能作为可靠的真机选择器。

该路径只需运行桌面与移动 App；使用官方配置时无需额外启动本地 signaling。
安装版 Release 不需要终端。自建服务、本地明文 `ws://` 调试、平台依赖、
Release 构建和 Host 打包见[从源码构建 Roammand](docs/BUILDING.zh-CN.md)。

桌面端和移动端提供相同的“网络服务”设置，可配置 signaling 与 STUN，并随时恢复官方配置。当前版本只尝试 ICE 直连，没有 TURN 中继兜底，因此部分严格网络环境仍可能连接失败。

## 安全设计

- 不需要云账号。
- 长期私钥和设备授权保存在设备本地。
- 只有 Host 本机批准后才会创建永久授权。
- signaling 不能批准控制。当前服务不解析、不持久化内层协议字节，但
  这种“不透明转发”实现方式不意味着字节对服务运维方保密。
- WebRTC 会保护两端之间的画面与输入流量。signaling 运维方可访问所转发
  的协商字节、公开身份材料与路由元数据；STUN 会看到映射请求的来源
  地址和时间。“无需账号”不等于“没有元数据”或匿名。
- Host 会持续显示控制状态，并提供本机“停止”和“紧急停止”。
- 会话恢复或图形会话切换期间会释放并阻止输入。
- 诊断信息不包含设备身份、网络地址、SDP/ICE、输入、屏幕、凭据或原始载荷。

准确的安全边界见[配对模型](docs/architecture/account-free-pairing-v1.md)、[特权会话桥接](docs/architecture/privileged-session-bridge-v1.md)、[威胁模型](docs/security/privileged-helper-threat-model.md)和[诊断策略](docs/security/privacy-safe-diagnostics.md)。

## 自托管

Roammand 提供固定版本的 signaling 与 STUN-only coturn Docker Compose 部署，
以非 root 服务、TLS 文件 secrets、健康检查、单一 UDP STUN 端口和有界日志运行。
signaling 状态由单实例保存在内存中，且该配置不提供 TURN 中继。参见
[Docker Compose 自托管](docs/self-hosting/docker-compose.zh-CN.md)。

## 项目文档

- [安装、授权、配对和故障排查](docs/user-guide/README.zh-CN.md)
- [构建、运行、打包和验证](docs/BUILDING.zh-CN.md)
- [品牌设计规范](brand/README.zh-CN.md)
- [架构](docs/architecture/README.zh-CN.md)
- [安全](docs/security/README.zh-CN.md)
- [官方 signaling 与 STUN 服务配置](docs/operations/official-service-profile.zh-CN.md)
- [测试与验证](docs/TESTING.zh-CN.md)
- [变更日志](CHANGELOG.zh-CN.md)
- [参与贡献](CONTRIBUTING.md)
- [报告安全问题](SECURITY.md)

## 许可证

Roammand 按仓库路径使用不同的开源许可证。复用或分发前，请阅读[许可证概览与第三方
声明责任](LICENSES.md)。
