# 应用图标来源

`codepet-icon-source.png` 是用户选定的 Code Pet / CodePet Remote 共用原图：黑猫、C 形卷尾、琥珀眼睛和白手套，米白底。

Android 原生资源位于 `android/app/src/main/res/mipmap-*/ic_launcher.png`，尺寸依次为 48、72、96、144、192 px。Manifest 使用 `@mipmap/ic_launcher`。源图仅用于导出，不作为 Flutter 运行时资源。

在 Code Pet 仓库执行 `python3 scripts/generate_app_icons.py --remote-root /path/to/codepet-remote` 可从统一原图重新生成；需要 Pillow 和 macOS iconutil。导出只缩放和转换格式。

更新后检查各密度尺寸，构建 Android 应用，并在实际启动器确认图标与白爪可见。启动器可能缓存旧图标，文件验证不能替代安装验证。
