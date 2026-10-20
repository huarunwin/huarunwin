# 运行与构建

文中的命令和源码路径以仓库根目录为基准。

版本固定在 `.fvmrc`，与参考项目 FlClash 的正式构建版本一致。

```sh
fvm use 3.47.6
fvm flutter pub get
fvm flutter run -d macos
fvm flutter build macos --release
fvm flutter build ios --simulator --no-codesign
fvm flutter devices --machine | jq '.[] | select(.targetPlatform | startswith("android"))'
fvm flutter run -d <Android设备ID>
fvm flutter build apk --debug
```

Android 正式渠道不能使用调试签名。复制 `android/key.properties.example` 为 `android/key.properties`，填写 Release 密钥路径、别名和密码，并把密钥文件保存在仓库之外；`key.properties` 与密钥文件已加入忽略规则。缺少有效配置时，本地 release 构建会明确失败。

本地 Debug 身份可用 `android/debug-signing.local.properties.example` 复制为 `android/debug-signing.local.properties` 后指定。已有身份迁移目录或更换 keystore 密码时保留原私钥和证书，不重新生成 Debug 身份。未提供该文件时仍使用 Android 默认调试配置，便于首次本地编译；已提供但不可用时不静默回退。

`storeFile` 建议使用构建机的绝对路径，模板中的 `/path/to/huarunwin-release.jks` 仅为占位符；Windows 路径可使用正斜杠。若使用相对路径，则以 `android/app` 为基准。缺少或未填完签名配置不影响 debug 构建；正式发布后须保管同一密钥及备份，不能靠换用调试签名完成覆盖升级。

GitHub Actions 的 Android 任务编译 Debug 应用与 instrumentation APK，PR 无需签名 Secrets；dev／tag 还会构建三种 ABI 的签名 APK，核对身份、版本和证书。Debug／Release 两组各五项签名 Secrets、产物清单和配置状态见[发布与许可](releasing.md)。本地仅编译 instrumentation（不运行设备测试）可在 `android/` 下执行 `./gradlew :app:assembleDebugAndroidTest -Ptarget-platform=android-arm64`，运行前按本机配置设置 `JAVA_HOME` 和 `ANDROID_HOME`。

本机统一通过 `fvm flutter ...` 使用 `.fvmrc` 指定的 Flutter SDK，避免受系统 PATH 中其他 Flutter 版本影响。IDE 的 Flutter SDK 路径可配置为项目内的 `.fvm/flutter_sdk`。GitHub Actions 使用固定提交的 Flutter Action 读取同一 `.fvmrc` 安装 SDK，核对实际版本后直接执行 `flutter`／`dart`；CI 不安装 FVM，详见[发布与许可](releasing.md)。

Dart 检查同样使用 `fvm dart ...`，例如 `fvm dart analyze lib test`。Android 构建所需的 JDK、Android SDK 和目标设备分别通过 `JAVA_HOME`、`ANDROID_HOME`、`ANDROID_SERIAL` 等标准环境变量配置；具体值由开发者在本地设置，不写入仓库。文档命令使用仓库相对路径或占位符，不包含个人用户目录、机器标识、代理配置及参考项目的个人检出位置。

客户端自身更新的本地 debug 运行默认使用 `debug` 渠道，release/profile 默认使用 `release`。`HUARUNWIN_UPDATE_CHANNEL` 只选择更新渠道，不自动更换本地签名文件；需要经过 release 优化且沿用 Debug 身份的测试包时，使用 CI 的 dev 预发布流程，由工作流明确选择 Debug Secrets。两类渠道的日志与下载地址均配置在公开仓库 `huarunwin-hub/api/updates.json`；详情见[发布与许可](releasing.md)。

纠错页的 Debug 与正式构建均固定使用 `https://huarun.win/corrections/app`，不再读取局域网覆盖参数。页面及样式是静态文件，提交仍使用网站既有在线接口；可直接运行客户端检查线上页面，验收无需提交真实纠错。

Windows 纠错页通过 [`webview_flutter_windows`](https://pub.dev/packages/webview_flutter_windows) 1.3.0 接入 WebView2，最低 Windows 10 1809，运行时需要 Microsoft Edge WebView2 Runtime。客户端检查运行时是否存在，缺失时提供官方安装页面；不会自动下载安装。插件使用当前用户 LocalAppData 下的独立网页数据目录保存会话，不在程序安装目录写入。新增原生插件后须重新编译 Windows 客户端，热重载无法添加原生能力。构建需要 Visual Studio 2022 C++ 工具链，插件通过 NuGet 获取 WebView2 SDK 与 WIL。

本机 Windows 使用目标架构对应的 Windows 主机与 FVM，执行 `fvm flutter build windows --release`；当前 Flutter 按运行 SDK 的主机架构选择 x64／ARM64。产物分别位于 `build/windows/x64/runner/Release` 和 `build/windows/arm64/runner/Release`。Windows CMake 禁用仅由 Android 依赖引入的 JNI 探测，客户端在 Windows 不依赖 JVM。CI 的 EXE／ZIP 包装另需 Inno Setup 6 及对应架构的 Visual C++ 可再分发运行库，详见[发布与许可](releasing.md)。

Windows 应用显示名称为“华润赢”，覆盖原生窗口标题、程序描述、安装器、快捷方式和卸载列表；主程序仍为 `huarunwin.exe`。名称变更从重新构建／打包后生效，既有 Release 附件保持原样。

macOS 产物：`build/macos/Build/Products/Release/华润赢.app`，应用名称统一为“华润赢”。最低 macOS 13，本机构建默认包含 arm64 和 x86_64，CI 按架构分别构建。构建自动编译并嵌入 Swift 安装助手。

macOS 窗口在 Flutter 首帧完成绘制后显示，避免冷启动初始化期间露出黑色空窗；目录网络请求异步进行，不作为显示窗口的条件。

自动打包及 runner 配置见[发布与许可](releasing.md)，检查命令和历史验证范围见[验证记录](verification.md)。
