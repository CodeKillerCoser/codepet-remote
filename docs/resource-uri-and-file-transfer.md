# 资源 URI 与文件传输 / 挂载设计

> 目标：在局域网下，Host 侧 AI 运行期间产生或需要的文件物料（图片、附件、Agent 构建的前端页面等），能够在手机端 Remote 上查看、下载、上传，并以一种与 HTTP 使用方式无差异的私有链接协议 `codepet://` 在内容中引用。

## 1. 核心不变式

整个方案围绕四条不变式展开，任何实现都不能破坏它们：

1. **唯一 mint 点**：资源引用（`codepet://` 链接、registry token）只在 Host 数据面一个地方创建。Remote 不凭空造引用，也不自行解析 token 的含义。
2. **唯一 resolve 点**：所有 `codepet://` 请求只在 Host 数据面一个地方解析成 registry 条目 / 实际文件。客户端和渲染层只负责"识别 + 转发"，不负责"解释"。
3. **文本不解析**：路径 → `codepet://` 的转换只发生在**结构化边界**（如 `ToolContent.uri`、Markdown 渲染 hook 的 `imageBuilder` / `onTapLink`），**绝不**对 Markdown 全文做全局文本替换。全文替换无法保证覆盖所有写法，也极易误伤。
4. **控制面 / 数据面分离**：不在 JSON-RPC 控制面上走 base64 大字节。字节（图片、文件、前端资源）一律走独立的 HTTPS 数据面；控制面只传引用（URI / token / 元数据）。

另有一条派生约束：

5. **身份与定位分离**：`codepet://` 里只携带 `hostDeviceId`（身份），不携带 `host:port`（定位）。定位信息（endpoint）由客户端已保存的配对结果决定，避免 IP 变化后链接失效。

## 2. URI 语法

私有协议为 `codepet://`，**只支持两种形式**：

| 形式 | 模板 | 语义 |
|---|---|---|
| path 形式 | `codepet://<hostDeviceId>/content/<relpath>` | 按路径解析（resolve-by-path），指向 Host 工作区内的相对路径 |
| id 形式 | `codepet://<hostDeviceId>/encrypt/<token>` | 按 id 解析（resolve-by-id），token 是 registry 的不透明 token |

- `hostDeviceId` 是 Host 的设备身份（配对时已确认并校验）。
- **资源类型（image / file / web-preview）不放进 URI 的第三段**，而是由元数据承载（`ToolContent.kind` / `mimeType` / `name` 等）。这样 URI 保持两个稳定形式，扩展资源类型不需要改链接语法。
- 使用方式与 HTTP 链接无差异：嵌在 WebView / ImageView / Markdown 里，加载时走自定义 Transport；若嵌入的是普通 HTTP 链接，则走正常网络加载。

## 3. 内容分类与转换边界

### 3.1 内容分类

- **image**：图片附件 / 截图，手机端预览（也可能下载）。
- **file**：任务产生或需要的任意文件，手机端查看、下载、上传。
- **web-preview**：Agent 构建的前端页面，手机端直接预览（Host 托管 + 手机渲染，不走文件传输）。

### 3.2 转换发生的位置

转换只在两个结构化切面发生，都是"结构化字段 / 组件切面"层面的操作：

1. **Host 侧（mint 点）**：provider 把 harness 输出的内容统一到标准协议时，对 `ToolContent.uri` 等结构化字段做转换——把可访问的本地文件 mint 成 `codepet://` 引用或 registry token。**只改结构化字段，不扫 Markdown 全文。**
2. **Remote 侧（上屏渲染）**：内容上屏时，Markdown 解析组件（`flutter_markdown_plus`）提供 `imageBuilder` / `onTapLink` 切面，在这里把 Markdown 里嵌入的链接改写成 `codepet://` 或直接走 `BlobAccess`。转换 policy 由 conversation feature 注入，不写死在通用组件里。

关于"Remote 侧替换 Markdown 链接会不会误替换"：这里展示的全部是远端内容（Host 上 AI 产生的对话物料），本机手机上的东西不会进入这个 App，因此误替换风险可接受。HTML 内嵌链接暂不处理，先覆盖 Markdown。

## 4. Host 数据面

Host 在既有 `/remote/v1/` HTTPS 服务下扩展两块能力，复用现有 pinned TLS + Bearer 信任体系。

### 4.1 内容注册表（content registry）

不透明 token → 条目，条目结构：

```
{ sourcePath | bytes, mimeType, name, size, scope, createdAt, expiresAt }
```

- **生命周期**：TTL + 访问时检查 + 周期 GC（有硬上限），不是"文件还在就无限延长"。过期即失效，Remote 访问不到时显示"已过期被清理"。
- token 为不透明、不可猜测的值（对应 `encrypt` 形式）。

### 4.2 预览 / 挂载服务（preview / mount）

- 路径：`/remote/v1/preview/<previewId>/`。
- 能力：静态资源托管 + dev-server 反向代理（含 WebSocket / HMR 转发）。
- 提供方式：做成一个工具（类似 MCP 工具），在启动 Harness 时注入，Agent 构建完前端后调用该工具把构建产物挂载上来，得到预览地址供手机端依赖。

## 5. 客户端数据面与渲染

- **图片**：自定义 `CodepetImageProvider`，识别 `codepet://` 并走自定义 Transport 加载。
- **文件**：`BlobAccess` 端口（传输无关），负责下载 / 上传字节；当前实现 `HttpsBlobAccess`（走 `/remote/v1` + pin），未来 `RtcBlobAccess`（接入外部 RTC 时只实现 channel contract，业务调用不变）。
- **前端预览**：`flutter_inappwebview`，做证书 pin + 子资源拦截。
- **Markdown**：`flutter_markdown_plus` 的 `imageBuilder` / `onTapLink` hook，policy 由 conversation feature 注入。
- **渲染入口**：`conversation_timeline_view` 里现在 `content.text ?? content.uri` 的纯文本展示，替换为按 kind 分发的预览 / 保存。

## 6. 安全模型

- 复用既有 pinned TLS（`PinnedTlsConnection`）+ Bearer token 信任体系。
- `codepet://` 里的 `hostDeviceId` 必须匹配已保存的配对设备身份，防止跨设备引用。
- `encrypt` token 不可猜测，registry 条目带 `scope` + TTL。
- 数据面 HTTPS 同样走证书 pin，不信任 mDNS / 网络名解析出来的地址。

## 7. 客户端分层落地

按既有向内依赖规则：

- **core/domain**：资源 URI 类型、`BlobAccess` 端口、`GatewayToolContent`（已含 `uri/mimeType/name/totalBytes`）。
- **application**：预览 / 下载 / 上传用例，链接替换 policy。
- **infrastructure**：`HttpsBlobAccess` / 未来 `RtcBlobAccess`、`CodepetImageProvider`、markdown hook、webview。
- **features**：`conversation_timeline_view` 上屏分发。

## 8. 落地顺序

1. **最小闭环**：Host registry + `/remote/v1` HTTPS 下载 + 图片预览。
2. **Markdown 链接替换 + 文件下载/保存**。
3. **web-preview 挂载**（前端页面托管 + 反代）。
4. **RTC 数据面**：新增 `RtcBlobAccess`，只实现 channel contract，Gateway 业务调用继续复用 `sdk/gateway`。

## 9. 未知项

- Markdown 里嵌套链接、相对路径与绝对路径的解析规则细节。
- 上传方向的挂载（手机 → Host）的交互与权限边界。
- RTC 数据面的字节通道与 `BlobAccess` 端口对齐方式。
- HTML 内嵌资源链接的替换时机与范围（暂缓）。
