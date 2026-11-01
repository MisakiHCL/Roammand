<!-- SPDX-License-Identifier: Apache-2.0 -->

<p align="center">
  <img src="brand/roammand-app-icon.svg" width="112" alt="Roammand 标志">
</p>

<h1 align="center">Roammand</h1>

<p align="center"><strong>离开桌面，工作仍在继续。</strong></p>

[English](README.md) · **简体中文**

Roammand 是一款无需账号的开源远程桌面应用。用手机、平板或另一台电脑，
控制你自己的 Windows 和 macOS 电脑，离开桌面后继续工作，或查看长时间运行的任务。

## 你可以做什么

- **配对一次，轻松重连。** 保存可信电脑，后续无需重复配对，并可在短暂中断后尝试恢复连接。
- **用手机操作桌面应用。** 支持触控手势、文本输入、修饰键和特殊按键。
- **掌握设备访问权。** 在被控电脑上查看连接者、本机停止会话，或撤销某台设备的访问权限。
- **选择连接服务。** 直接使用内置官方服务，也可通过
  [Docker Compose 自托管 signaling 与 STUN](docs/self-hosting/docker-compose.zh-CN.md)。

## 平台支持与下载

**Host 是被控电脑，Controller 是你用来操作它的控制端。当前只有 macOS 提供公开安装包。**

| 平台 | 角色 | 获取方式 |
| --- | --- | --- |
| macOS 14.4 或更高版本（Universal） | 被控端与控制端 | [下载 `Roammand.pkg`](https://github.com/MisakiHCL/Roammand/releases/latest/download/Roammand.pkg) |
| Windows 10 / 11 | 被控端与控制端 | 源码构建，暂无公开安装包；安装版被控端以 Windows 11 为验证基准。 |
| iOS / iPadOS 15 或更高版本 | 仅控制端 | 源码构建或维护者邀请测试，暂无公开 App Store 下载。 |
| Android 7.0 或更高版本（API 24） | 仅控制端 | 源码构建，暂无公开安装包。 |

macOS 1.1.0 安装包经过 Developer ID 签名，但**未经 Apple 公证**，Gatekeeper 可能会阻止打开。
版本说明和资产摘要见 [Releases](https://github.com/MisakiHCL/Roammand/releases)。
在公开移动版列于此处之前，移动端源码构建和邀请测试版本用于开发与实体设备验证。

## 如何使用

可以先用两台 Mac 体验，也可以使用一台 Mac，加上按上表准备好的移动控制端。

1. **准备被控 Mac。** 安装 Roammand，打开“**此电脑**”，完成“**屏幕录制**”和
   “**辅助功能**”两项设置；权限就绪后，被控端才会变为可用。
2. **打开控制端。** 另一台 Mac 安装同一软件包后，打开“**我的电脑**”；手机或平板使用源码构建或受邀测试版本。
3. **配对并批准。** 移动端：在被控 Mac 上创建实时二维码邀请，用控制端扫描，再在 Mac 上批准名称正确的设备。
   电脑端：在被控电脑上创建一次性桌面配对码，在控制端输入，核对两端显示的全部四个英文验证词，再由被控端批准名称正确的控制端。
4. **连接使用。** 在控制端的“**我的电脑**”中选择已保存的 Mac，点击“**连接**”。

详细的安装、配对、故障排查和卸载步骤见[用户指南](docs/user-guide/README.zh-CN.md)。

## 当前限制

- 一台被控电脑同时只接受一个控制端会话，仅共享主显示器。
- 不包含音频、剪贴板同步、文件传输、云同步或自动更新。
- 移动端仅在前台运行，切到后台会关闭会话；iOS/iPadOS 界面仅支持横屏。
- 官方及随附的自托管配置均**不提供 TURN 中继**，严格网络中的直连可能失败。
- 锁屏/登录界面控制需要安装版 Host 组件和系统权限。不支持所有者首次登录前的访问、
  完全登出或 Host 退出后的持续控制，以及 FileVault 预启动阶段。

## 从源码开始

客户端使用 Flutter，被控端使用 Rust，signaling 服务使用 Go。
按[构建、运行、打包和验证](docs/BUILDING.zh-CN.md)安装依赖后，在 macOS 的仓库根目录运行：

```bash
make bootstrap
make app-check
make app-run-macos
```

移动端和 Windows 构建、打包与详细日志说明也见该指南。

## 安全设计

配对须由被控电脑本机批准，并保存单向授权；反向控制需要单独配对。
长期私钥和授权保存在设备本地，signaling 不能授予控制权限。
具体机制见[配对模型](docs/architecture/account-free-pairing-v1.md)。

WebRTC 保护设备之间的画面与输入流量；signaling 和 STUN 运维方仍可观察协商或网络元数据，
“无需账号”不等于匿名。详情见[安全](docs/security/README.zh-CN.md)指南、
[诊断策略](docs/security/privacy-safe-diagnostics.md)及官方运营方的
[隐私政策](https://hclgame.com/roammand/privacy)。

## 项目文档

- [架构](docs/architecture/README.zh-CN.md) · [品牌设计规范](brand/README.zh-CN.md)
- [官方 signaling 与 STUN 服务配置](docs/operations/official-service-profile.zh-CN.md)
- [测试与验证](docs/TESTING.zh-CN.md)
- [变更日志](CHANGELOG.zh-CN.md) · [参与贡献](CONTRIBUTING.md) · [报告安全问题](SECURITY.md)

## 许可证

Roammand 按仓库路径使用不同的开源许可证。复用或分发前，请阅读[许可证概览](LICENSES.md)。
