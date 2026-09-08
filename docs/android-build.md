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
`debug` 仍使用临时 debug 签名，不用于覆盖正式签名版本。

在 **Settings → Secrets and variables → Actions** 配置以下 Repository secrets：

- `CODEPET_RELEASE_KEYSTORE_BASE64`：正式 `.jks` 文件的 Base64 内容。
- `CODEPET_RELEASE_STORE_PASSWORD`：keystore 密码。
- `CODEPET_RELEASE_KEY_ALIAS`：签名密钥别名。
- `CODEPET_RELEASE_KEY_PASSWORD`：签名密钥密码。

流水线仅在 release 构建步骤注入密钥，将 keystore 还原至 runner 临时目录，构建结束后删除。
密钥和密码不得提交到仓库。

## Android 发布签名

当前开发阶段，Release 缺少正式签名配置时会回退使用 debug keystore，保证 APK
可以直接安装测试。正式发布前通过 Gradle property 或环境变量提供以下四项，
配置完整时会自动改用正式签名：

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
