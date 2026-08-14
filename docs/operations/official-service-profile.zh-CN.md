<!-- SPDX-License-Identifier: Apache-2.0 -->

# 官方 signaling 与 STUN 配置

[English](official-service-profile.md) · **简体中文**

当前官方服务配置使用无账号信令与公共 STUN：

- 信令：`wss://signal.hcl.life/v1/connect`
- STUN：`stun:stun.hcl.life:3478`
- ICE 策略：`all`
- TURN 中继：不提供
- 运营者：ChengLong Hu
- 隐私联系邮箱：`misakihcl@gmail.com`
- 隐私政策：<https://hclgame.com/roammand/privacy>
- 基础设施：腾讯云新加坡地域

信令属于 WebSocket 流量，可以经过 HTTP 反向代理。STUN 属于 UDP 流量，必须通过直连 DNS 或兼容的四层负载均衡暴露。`https://hcl.life/stun/` 这样的路径不能承载 STUN，普通网站 CDN 也不能替代 UDP 3478。

## 部署边界

公开客户端可以包含官方域名和端口，但不得包含基础设施凭据、私钥、源站地址、SSH 别名、证书路径或运维人员本地路径。STUN 没有密码，也不会中继会话流量。

WSS 会在 signaling 终止，因此运维方可以访问正在转发的有界内层 envelope
字节，包括公开身份证明和 WebRTC 协商元数据，也可观察来源地址、已注册路由标识符、
时间和流量大小。当前服务不解析、不持久化、通常也不记录内层正文，但这种数据
最小化实现并非对运维方的端到端保密。还必须限制对代理、运行时和基础设施遥测的访问。
本仓库不为官方配置定义可用性或支持 SLA；需要自行控制可用性的部署应使用自托管配置
和自己的监控体系。

官方部署没有 Roammand 业务数据库。在线状态、配对 rendezvous、限流窗口和活动路由
只保存在进程内存中，重启后清空；信令消息不会被有意持久化。WebSocket 端点关闭了
常规 Nginx access log。基础设施错误日志和服务日志仍可能为了安全、滥用防护与可用性
包含网络地址和时间信息。Nginx 日志每天检查一次，非空时最多保留 14 个轮转归档；
系统与 coturn 的 syslog 每周检查一次，非空时最多保留 4 个轮转归档；system journal
按容量管理，目前没有固定的时间上限。这些是轮转数量限制，并不保证每条记录都保留
固定天数。部署脚本不会备份 Roammand 信令状态或日志。

信令进程在反向代理后只监听私有接口。代理必须覆盖 `X-Real-IP`，服务仅在直连来源属于 `SIGNALING_TRUSTED_PROXY_CIDRS` 时信任该请求头。绝不能把整个互联网配置成可信代理。

## 客户端接入

Release 构建包含可恢复的官方配置，并提供 signaling 与 STUN 的运行时自定义配置。选中的配置会传给 GUI 自己管理的 Host Agent。开发者仍可通过明确的环境变量或 Dart definitions，独立运行 signaling、Host Agent 和 Flutter。

Host 修改信令地址后会重启 GUI 管理的 Agent。之前配对的 Controller 会继续保存旧地址，直到经过认证的重新配对为同一 Host 身份替换绑定。STUN 是设备本地 ICE 输入，不会写入配对二维码。

## TURN 中继边界

当前官方配置不包含 TURN，因为它会中继高带宽加密流量，需要滥用控制、allocation
限额、容量监控和短期凭据。任何独立运维的 TURN 部署都应使用直连 DNS 或四层负载
均衡，并且绝不能把长期 TURN 密码写入客户端。
