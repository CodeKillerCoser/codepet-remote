# 界面设计与组件分层

参考 FlClash 的分层设计，由 CodePet Remote 独立实现；未引入其源码或 Prism UI 依赖。

## 职责

- `lib/ui/theme/app_theme.dart`：缓存浅色和深色主题，统一语义色、字号、文字行距、按钮、输入框、菜单、卡片、列表和弹层。设置页提供跟随系统、浅色、深色三种模式，选择由 `lib/app/theme_preferences.dart` 持久化并即时生效；保留系统文字缩放。
- `lib/ui/layout/app_layout.dart`：公共圆角、按钮高度、间距、页面边距和内容最大宽度。手机边距 16，宽屏 24；卡片间距随视口为 8 / 12 / 16。
- `lib/ui/layout/app_scaffold.dart`：页面骨架，约束宽屏内容至 960，统一底部操作区分隔线和系统栏图标明暗。键盘避让策略仍由业务页面传入。扫码预览显式使用全宽。
- `lib/ui/components/`：分组表面、次要行菜单与 AppNavigationDrawer 导航抽屉。菜单只管理外观及交互入口，实际选项和回调由业务组件传入。
- `lib/features/`：设备、配对、首页、搜索、设置和会话页面依赖以上公共层，业务逻辑、消息协议及队列生命周期不放入 UI 基础层。

## 使用规则

颜色优先引用 `Theme.of(context).colorScheme`，文字引用 `textTheme`。公共组件默认尺寸通过主题调整，业务专用密度通过 `AppLayout` 调整。新页面使用 `AppScaffold`，避免重新实现宽屏和系统栏策略。

抽屉使用全局 DrawerTheme 与 ListTileTheme：标题沿用 titleLarge，说明沿用 bodySmall，设备与操作入口统一为 ListTile；选中项使用 secondaryContainer / onSecondaryContainer，不在页面额外加粗或绘制图标底块。抽屉宽度、边距与图标尺寸由 AppLayout 管理。设置固定在底部，设备列表独立滚动。进入子页面直接压栈，返回保留抽屉展开状态，再次返回关闭抽屉；选择设备则关闭抽屉并切换首页内容。

会话正文保持可选中及自然换行；队列是单行摘要，显示时折叠空白，超长省略，不修改实际发送文本。队列菜单只含引导、重新编辑、删除。错误提示使用低强度错误背景和清晰的错误色文字，保留完整说明，不改变失败次数或队列暂停语义。

## 语义样式与业务组件

- `AppSemantics` 是注册到 ThemeData 的 ThemeExtension，统一成功/运行中、警告/待处理、未读状态色，并支持明暗模式与主题插值。错误、正文、表面继续使用 Material ColorScheme。
- `AppThemeRoles` 从当前 TextTheme 派生强调文字、普通/未读标题、状态标签、流量文字、等宽代码和 Toast 正文；功能页面不直接指定字号、字体和字重。
- `AppMarkdownTheme` 管理 Markdown 正文、代码、引用、表格的视觉规则。解析、链接操作和复制仍属于功能层。
- 审批背景、低强度错误背景、选中边框和浮层阴影统一由主题角色派生；Toast 渲染强度由 AppEffects 定义。
- AppLayout 的 spacing scale 管理公共间距；保留既有队列密度、气泡尾角、控件布局。零间距、透明材质、系统安全区/键盘尺寸、图标几何和滚动/动画参数属于布局与交互，不作为颜色或文字 token。
- 样式防回退检查禁止 lib/features 中新增硬编码调色板、字号、字重或字体；主题角色测试覆盖明暗对比度和现有未读组件替换主题后的实际颜色。

## 验证

修改公共主题后运行 `flutter analyze` 和 `flutter test`，并构建 Android APK。基础层测试覆盖明暗主题、宽屏内容限制、底部栏高度以及系统字体缩放；模拟器检查首页、会话队列与菜单、设置页。新交互不能只靠截图验证，需要保留对应业务组件测试。

## 本次验收（2026-11-10）

- `flutter analyze`：通过。
- `flutter test`：479 项通过，包括既有页面交互和新增基础层测试。
- `flutter build apk --debug`：通过，并覆盖安装至 Android API 36 模拟器。
- 实机截图检查：首页、设置、会话浅色和深色布局正常；系统主题检查后恢复浅色。截图位于本地 `artifacts/design-system/`（不纳入源码）。最后一次菜单复查时 Host 断线，未执行真实队列操作；菜单交互由既有 widget 测试覆盖。

## 语义主题收口验收（2026-11-10）

- 静态检查通过，489 项测试通过，包含语义色对比度、主题替换、功能层样式防回退检查。
- Debug APK 本地构建并覆盖安装至 API 36 模拟器，保留设备配对和会话数据。
- 检查首页、抽屉、设置、已有 OpenCode 会话的浅色/深色效果；确认队列单行、错误提示、状态色可见。未发送消息或处理队列；主题检查后恢复跟随系统。
- 截图位于本地 `artifacts/semantic-theme/`，不纳入源码。


## 字号与原生启动主题

- AppTypography 显式定义完整 TextTheme：页面标题 20、列表标题/输入文字 16、正文/按钮/代码 14、辅助说明 12、紧凑标签 11。Markdown 代码不再按正文乘 0.9；系统 TextScaler 保留。
- AppSurface 的浅边框与 AppRowMenu 的淡色箭头分别读取主题 subtleBorder、secondaryActionIcon，不在组件内拼透明度。
- Android 普通窗口、旧版启动 drawable 和 Android 12+ 系统启动背景均读取 app_surface 的日/夜资源，测试校验它们与 Flutter surface 一致。
- Android 12+ 通过 ThemeBridge 同步保存/恢复的主题选项给 UiModeManager；跟随系统撤销 App 自己的夜间配置。旧版 Android 在 Activity 创建时读取已有偏好来选择窗口资源；系统启动预览本身仍由旧版 OS 决定。
- 参考 [Android 官方深色主题指南](https://developer.android.com/develop/ui/views/theming/darktheme)。已在 API 36 模拟器验证系统浅色下选择 App 深色后的冷启动背景，并验证恢复跟随系统。
