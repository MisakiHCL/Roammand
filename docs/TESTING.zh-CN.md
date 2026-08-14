<!-- SPDX-License-Identifier: Apache-2.0 -->

# 测试与验证

[English](TESTING.md) · **简体中文**

Roammand 使用确定性自动化门禁验证仓库改动；必须依赖真实设备、网络、权限、安装器
或受保护操作系统桌面的行为，则通过聚焦的目标系统检查验证。公开文档只定义预期行为；
发行签字记录和真实环境证据不保存在公开仓库中。

## 自动化门禁

在仓库根目录运行完整门禁：

```bash
make test-product
```

开发过程中可以运行范围更小的命令：

| 范围 | 命令 | 覆盖内容 |
| --- | --- | --- |
| 格式与源码契约 | `make format-check` | Rust、Go、Dart、生成代码和仓库规则 |
| 协议与原生服务 | `make test` | Schema 兼容、signaling、身份、IPC、配对、WebRTC、恢复、Bridge、隐私和打包契约 |
| Flutter 产品 | `make app-check` | 本地化生成、格式、静态分析和 Widget/单元测试 |
| 协议生成 | `make generate-check` 与 `make test-conformance` | 可复现生成代码和跨语言密码学向量 |
| 平台构建 | `make app-build-macos`、`make app-build-ios-simulator`、`make app-build-android` | 支持的源码目标构建集成 |
| macOS 安装包 | `make package-macos` | 打包白名单、manifest、合规材料和安装/卸载 dry-run 契约 |

自动化通过不能证明某台真实设备上的画面采集、输入注入、相机访问、NAT 穿透、
受保护桌面或安装器一定可用。

## 目标系统矩阵

| 范围 | 最低实体验证要求 |
| --- | --- |
| macOS Host | macOS 14.4+ 安装、屏幕录制与辅助功能就绪、采集、输入、托盘可见、本机停止、锁屏/LoginWindow 切换和完整移除 |
| Windows Host | Windows 11 安装、服务就绪、采集、输入、本机停止、锁屏/UAC/Winlogon、SendSAS 策略边界和卸载行为 |
| 桌面 Controller | macOS 到 Windows、Windows 到 macOS 的认证画面/输入、显式关闭、授权撤销和重复清理 |
| iOS/iPadOS Controller | 相机配对、两个横屏方向、手势、键盘、安全区域、后台释放、显式重连和 Host 本机停止 |
| Android Controller | 相机配对、横竖屏、手势、键盘、安全区域、后台释放、显式重连和 Host 本机停止 |
| 网络 | 同局域网 ICE 直连，以及独立公网之间由 STUN 辅助的 ICE 直连；官方配置没有 TURN，受限网络必须清晰失败 |
| 恢复 | signaling/网络中断、全新认证恢复、有界重试、输入释放、进程失败和重复连接/关闭 |
| 隐私 | 诊断预览/导出、有界资源观测、日志脱敏、不可信 frame 拒绝和自托管服务限制 |

锁屏、登录、UAC、Winlogon、LoginWindow、系统服务和卸载必须使用安装包验证。
报告 `user_session_only` 的源码运行、模拟器、交叉编译或 package dry run 都不能替代
这些检查。

## 配对与授权

- 二维码配对只接受实时相机扫描，并能正确处理相机权限被拒绝。
- 桌面配对码在 120 秒内过期，本身不会授予访问权限。
- 两台桌面设备显示完全相同的四个英文验证词。
- Host 只有在本机批准后才创建单向永久授权。
- 保存的 Host 可直接重连；Host 侧撤销会阻止后续会话，Controller 侧删除只影响本机。
- 设备身份在普通重启后仍保存在平台受保护存储中，且不会通过移动端云备份恢复到另一设备。

## 会话与生命周期

- 验证画面、指针、单击、拖动、滚动、文字、修饰键和特殊键。
- 确认权限丢失、进入后台、路由切换、恢复、本机停止、紧急停止、撤销和进程失败都会释放已按住的输入。
- 重复执行连接、受保护桌面切换、解锁和断开，观察是否出现按键卡住、重复指示器、过期会话或持续增长的进程/资源。
- Debug 专用的局域网明文 `ws://` 只能作为开发证据；跨网络发行验证必须使用 WSS 和配置的公共 STUN。
- 可选的开发者自建 TURN 只验证底层 relay 路径，不表示官方服务提供 TURN。

## 证据边界

内部签字记录只保存必要的操作系统版本、设备类别、包版本、粗粒度网络场景、日期和
结果，并使用合成名称与端点。测试证据不得保留配对码、设备身份、凭据、私钥、
SDP/ICE、精确网络拓扑、输入、屏幕内容、会话 transcript、原始载荷或未脱敏诊断。

架构不变量见[架构指南](architecture/README.zh-CN.md)，诊断限制见
[隐私安全诊断](security/privacy-safe-diagnostics.md)。
