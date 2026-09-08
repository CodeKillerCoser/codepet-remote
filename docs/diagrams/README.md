# README 架构图生成记录

使用内置 imagegen 生成，图内标注使用简体中文。生成日期：2026-09-09。

- `system-architecture.png`：系统协作图。
- `client-architecture.png`：客户端分层图；实线为依赖关系，虚线为接口实现。

修改架构时，请同时更新 README 文字、图片和提示词，并核对箭头方向与中文标注。

## 系统协作图提示词

Use case: infographic-diagram. Create a polished Chinese software system architecture image for CodePet Remote GitHub README. Wide landscape 1800x900 approximately, pale warm white background, deep teal typography, mint rounded cards, restrained amber accent, crisp flat technical diagram with generous space. All visible labels Simplified Chinese only, no English. Title exactly "系统协作：手机交互，电脑执行". Left independent card with phone icon titled "手机客户端", subtitle "查看会话 · 发送指令 · 接收输出". Right large boundary titled "电脑端" contains three cards left to right: "主机网关" with subtitle "统一接入与会话路由"; "工具适配插件" with subtitle "能力描述与协议适配"; "编程工具与项目环境" with subtitle "执行任务 · 管理项目". Exactly bidirectional arrows connect 手机客户端 ↔ 主机网关 ↔ 工具适配插件 ↔ 编程工具与项目环境. Only arrow between phone and gateway crosses computer boundary, label "局域网加密连接". Two small chips below phone-to-gateway arrow "证书指纹校验" and "设备凭据认证", no extra edges. Bottom caption exactly "手机负责交互，主机统一接入，工具在电脑上执行". Sharp readable Chinese text, professionally balanced visual hierarchy. No clouds, no internet nodes, no invented integrations, no watermark.

## 客户端分层图提示词

Use case: infographic-diagram. Create a polished Simplified Chinese architecture diagram for CodePet Remote GitHub README. Landscape 1800x1100 approximately. Warm white background, deep teal text, mint rounded cards, restrained amber accent, flat clean engineering infographic with generous whitespace, high readability. Every visible label Chinese only. Title exactly "客户端分层：依赖向内，职责清晰". Use six boxes, with exact labels: left vertical box "应用入口" subtitle "依赖装配与生命周期"; upper middle "界面层" subtitle "页面与交互"; center middle "应用层" subtitle "用例编排与会话控制"; bottom middle "领域层" subtitle "领域模型与状态"; right middle "端口接口" subtitle "网关、配对与设备契约"; upper right "基础设施适配器" subtitle "网关 · 配对 · 发现 · 存储". Directed solid arrows EXACTLY these six: 应用入口 → 界面层; 应用入口 → 应用层; 应用入口 → 基础设施适配器 (route along top margin); 界面层 → 应用层; 应用层 → 领域层; 应用层 → 端口接口. One and only one directed dashed arrow: 基础设施适配器 → 端口接口, label "实现接口". Arrowheads must terminate at specified destination. No other arrows, no cycles, avoid crossing lines and crossing cards. Bottom legend "实线：依赖关系" and "虚线：接口实现". Bottom caption "领域层不依赖界面、网络或生成代码". No English, no watermark, no faux code, no additional architectural components.
