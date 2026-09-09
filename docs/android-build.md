# Android 构建与发布

[文档导航](README.md) · [项目首页](../README.md)

## GitHub Actions 打包 Android APK

将 `.github/workflows/android-build.yml` 合入仓库默认分支后，在 GitHub 仓库中：

1. 打开 **Actions → Android APK → Run workflow**。
2. 在 **Use workflow from** 下拉框选择要打包的分支；目标分支也需要包含该工作流文件。
3. 选择 `build_mode`：默认 `release`，也可选择 `debug`，然后点击 **Run workflow**。
4. 构建成功后，在本次运行页面的 **Artifacts** 下载 `codepet-remote-…`，解压获得可安装的 APK。产物保留 14 天。

流水线使用所选分支的代码和 `pubspec.yaml` 版本号，生成包含各支持架构的通用 APK。
手动流水线的 `release` 使用仓库 Actions Secrets 中的固定签名；缺少配置时直接失败，
不会回退到临时 debug 签名。与本地使用同一密钥签名的旧版可覆盖安装（版本号不得降低）。
本地和 CI 的 Debug APK 使用仓库内同一份固定调试签名，无需配置 Secrets。

在 **Settings → Secrets and variables → Actions** 配置以下 Repository secrets：

- `CODEPET_RELEASE_KEYSTORE_BASE64`：正式 `.jks` 文件的 Base64 内容。
- `CODEPET_RELEASE_STORE_PASSWORD`：keystore 密码。
- `CODEPET_RELEASE_KEY_ALIAS`：签名密钥别名。
- `CODEPET_RELEASE_KEY_PASSWORD`：签名密钥密码。

流水线仅在 release 构建步骤注入密钥，将 keystore 还原至 runner 临时目录，构建结束后删除。
正式密钥和密码不得提交到仓库。

## Android 调试签名

Debug 固定使用 `android/keystore/codepet-debug.keystore`，该公开调试密钥按用户要求纳入仓库。
别名为 `androiddebugkey`，store/key 密码均为 `android`；构建时不得重新生成。
这使本地和 CI 后续 Debug 包保持签名一致；覆盖安装还要求包名一致、版本号不降低。
此前使用其他签名的安装包不能直接由这份新签名覆盖。

2026-09-09 已构建启用 WebRTC 的 Debug APK，并通过 apksigner 校验：
包名 `com.codepet.remote`，证书 SHA-256 为
`15d8c13ab1ae0aefa0010c7a90d7f2eed2883be2f1be9ec399beb7555d537860`。
调试密钥用途与指纹见 [keystore 说明](../android/keystore/README.md)。

## Android 发布签名

通过 Gradle property 或环境变量提供以下四项。Release 缺少配置时拒绝打包，
不回退到调试签名。覆盖安装还需保持签名、applicationId 一致、版本号不降低：

```text
CODEPET_RELEASE_STORE_FILE
CODEPET_RELEASE_STORE_PASSWORD
CODEPET_RELEASE_KEY_ALIAS
CODEPET_RELEASE_KEY_PASSWORD
```

Android SDK 首次使用需要由开发者本人阅读并接受 Google 许可证：

```sh
flutter doctor --android-licenses
```
