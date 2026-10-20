# 发布与许可

文中的命令和源码路径以仓库根目录为基准。

项目仓库统一归属 [huarunwin](https://github.com/huarunwin) GitHub 组织，维护者个人账号为 `freephilx`：[客户端源码与安装包](https://github.com/huarunwin/huarunwin)、[公共更新资源](https://github.com/huarunwin/huarunwin-hub)。

## GitHub Actions 自动打包

工作流为 [release.yml](../.github/workflows/release.yml)，配置打包 Android、macOS 和 Windows，使用 GitHub 标准托管 runner：

- 推送到 `dev`：成功后移动固定 `pre` tag，覆盖同一个预发布 Release 的说明及安装包，不占用正式版的 Latest 标记。发布前核对 dev 的最新提交，已过时的任务不覆盖 Release。
- 推送正式 tag：仅接受 `vX.Y.Z`，例如 `v0.1.0`、`v1.2.3`。三段数字不得有前导零，不接受缺少 `v`、额外版本段、`-rc.1` 或 `+构建号` 等格式。工作流按三段数字 tag 筛选，在安装工具链前核对格式及公开 Hub `api/updates.json` 的 `release.releases` 中对应的唯一、非空日志。Hub 缺少版本、日志无效或读取失败均停止构建。`pre` 是 dev 自动维护的唯一例外，不触发新构建；dev／PR 不要求 Hub 预备日志，测试包统一由 dev 发布。
- 支持手动运行 dev 或 tag；main 及其他分支手动运行时跳过所有任务，发布脚本也拒绝这些分支生成发布元数据。main 推送和面向 main 的 PR 不触发工作流。检查、测试、Android 签名校验、Mac 及 Windows 打包全部成功后才更新 Release。安装包先上传成功，再替换旧说明、清理旧附件；上传失败保留上一版。
- dev 推送与面向 dev 的 PR 仅修改 Markdown 文档、`docs/` 资料或 `.gitignore` 时不触发工作流；`docs/privacy.md` 是随包资源，单独保留构建触发。源码、测试、构建脚本、工作流、依赖配置、资源和 `LICENSE` 等其他文件的变更仍触发检查与编译。路径筛选不影响版本 tag 推送和手动运行。
- 产物为 Android `armeabi-v7a`、`arm64-v8a`、`x86_64` 三份 APK，macOS 的 Apple Silicon `arm64`、Intel `amd64` 两份 DMG，Windows `amd64`／`arm64` 各一份安装版 EXE 和便携 ZIP，以及 Android 签名清单和 SHA-256 校验文件。校验文件覆盖上述全部附件，不另行上传日志 JSON。macOS 当前使用 ad-hoc 签名，尚未配置 Developer ID 签名和 Apple 公证；Windows 尚未配置 Authenticode 签名。各平台实际构建和安装验收状态见[验证记录](verification.md)。
- Flutter 版本固定读取 `.fvmrc`。预发布名称为 `基础版本-pre.运行序号`，Android `versionName`、Windows 文本版本资源及 Dart 中的版本保留完整预发布标识，Mac 原生版本和 Windows 数字版本字段保持数字格式。内部构建号使用 Actions 的运行序号；Flutter 3.47.6 的 Android 分架构 APK 在该值上分别增加 1000／2000／4000，流水线验证实际版本码，升级 Flutter 时须同时复核此规则。

检查与 Android 构建固定使用 `macos-15`，Mac 构建矩阵分别使用 `macos-15`（Apple Silicon）和 `macos-15-intel`（Intel）。GitHub 镜像提供 Xcode、Python 3、CocoaPods、Homebrew 和 Android SDK；Android 任务另固定 Temurin JDK 17。工作流先校验更新日志，再使用固定提交的 `subosito/flutter-action`，通过 `flutter-version-file: .fvmrc` 安装指定 Flutter SDK；构建脚本核对实际 SDK 版本与 `.fvmrc` 一致后，直接调用 Action 配置的 `flutter`／`dart`。本机继续使用 FVM。dev／PR 启用 SDK 与依赖缓存，正式 tag 从干净 SDK 安装开始。Android 编译 Debug 应用及 instrumentation APK，确保 Kotlin、Manifest 和原生测试源码进入编译；此步骤不启动设备或运行 instrumentation 测试。Mac 每个架构独立构建，打包前核对主程序与安装助手均仅包含目标架构，并验证应用签名；DMG 中提供应用和 Applications 快捷入口，不再生成 Universal 包或 ZIP。发布任务使用 `ubuntu-24.04`，等待检查、Android、两个 Mac 和两个 Windows 构建全部成功后，合并同次运行的构建附件、生成 SHA-256 并上传 Release。

Windows 参照 [FlClash 的构建矩阵](https://github.com/chen08209/FlClash/blob/main/.github/workflows/build.yaml)，分别使用 `windows-2022`（x64）与 `windows-11-arm`（ARM64），独立实现打包脚本，不复用代理服务或强制结束进程的安装逻辑。两种架构均通过 Flutter Action 读取 `.fvmrc`。x64 使用 `stable` 安装通道；ARM64 因 stable 缺少原生主机 SDK 压缩包，参照 FlClash 使用 `master` 安装通道克隆 Flutter 后检出 `.fvmrc` 指定的精确 tag，由该 SDK 获取原生 ARM64 Dart；不跟随 master 最新提交。CI 不再下载 FVM 或维护其架构、入口与摘要配置。Windows Python 开启 UTF-8 模式以保存中文日志。PR 编译两种架构的 Debug 应用，dev／tag 构建 release 模式的完整运行目录。

[package_windows.ps1](../tool/ci/package_windows.ps1) 从 Visual C++ Redist 的有效数字版本目录中按版本降序查找对应架构的运行库，跳过 `v143` 等工具集目录名；仅收集匹配目标架构的运行库，再用 dumpbin 核对运行目录中各 EXE／DLL 引用的 Visual C++ DLL 均已随包提供，核对实际 PE 架构、应用身份和完整文本版本。便携 ZIP 包含主程序、插件 DLL、运行库及 Flutter data；[windows_setup.iss](../tool/ci/windows_setup.iss) 使用 Inno Setup 6 包装相同目录，默认安装到当前用户的应用目录，展示项目许可并提供开始菜单入口及可选桌面快捷方式。安装器使用稳定的应用 ID，覆盖安装沿系统确认和 Restart Manager 关闭应用流程，不调用 `taskkill`；卸载程序不删除客户端用户数据。WebView2 Runtime 缺失时仍由客户端引导打开微软官方渠道，不在打包或安装中静默下载。安装器资源中的厂商、产品名、完整版本和安装器标记须通过验证后才能上传。

Android 本地 Debug 构建可通过忽略的 `android/debug-signing.local.properties` 指定固定调试身份，模板见 [`debug-signing.local.properties.example`](../android/debug-signing.local.properties.example)；未配置时使用 Android 默认调试密钥。文件存在但配置无效时明确失败。本地 release 构建使用 `android/key.properties`，模板见 [`key.properties.example`](../android/key.properties.example)，缺失时不回退调试签名。两份配置与密钥、密码均不得提交。

CI 在仓库 Settings → Secrets and variables → Actions 配置两组固定身份。dev 的 `debug` 更新渠道使用 `ANDROID_DEBUG_*`，正式 tag 的 `release` 渠道使用 `ANDROID_RELEASE_*`。两种渠道都采用 release 编译优化，签名按更新渠道分别选择；没有回退到另一组的逻辑。

| Debug Secret | Release Secret | 内容 |
| --- | --- | --- |
| `ANDROID_DEBUG_KEYSTORE_BASE64` | `ANDROID_RELEASE_KEYSTORE_BASE64` | 对应 keystore 文件的 Base64 内容，允许换行 |
| `ANDROID_DEBUG_KEYSTORE_PASSWORD` | `ANDROID_RELEASE_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_DEBUG_KEY_ALIAS` | `ANDROID_RELEASE_KEY_ALIAS` | 密钥别名 |
| `ANDROID_DEBUG_KEY_PASSWORD` | `ANDROID_RELEASE_KEY_PASSWORD` | 私钥密码 |
| `ANDROID_DEBUG_SIGNING_CERT_SHA256` | `ANDROID_RELEASE_SIGNING_CERT_SHA256` | 该证书的完整 SHA-256 指纹，64 位十六进制或冒号分隔格式 |

[release.py](../tool/ci/release.py) 从已经核验的发布身份导出签名前缀，工作流仅将该渠道的五项 Secrets 映射到构建脚本的通用环境变量。[android_release.py](../tool/ci/android_release.py) 在临时目录还原密钥、临时创建忽略的 `key.properties`，无论成功或失败都清理自己创建的配置，不覆盖已有本机配置。缺少对应渠道 Secrets 会阻止发布；CI 不生成替代密钥。

每份 APK 都须通过 `apksigner verify`、当前渠道的固定证书指纹、应用 ID `win.huarun.huarunwin`、完整版本名称、预期版本码及实际原生库 ABI 检查。正式 `release` 渠道额外拒绝 Android Debug 证书；`debug` 渠道只接受其已配置的精确证书，不接受任意 runner 自动生成的调试身份。公开的 `*-android-signing.json` 记录渠道、文件名、应用身份、版本、证书和文件 SHA-256，供下载者核对；其中没有私钥或密码。这些检查不代替源码与二进制一致性证明或真实覆盖升级验收。

2026-10-20 按维护者要求保留现有 Debug 证书身份，另建独立 Release 密钥，并写入仓库的上述 10 项 Actions Secrets，已核对名称齐全。两份 keystore 和仅供本机使用的 `android-signing.json` 密码配置保存在维护者指定的私有目录，权限分别为目录 700、文件 600，并排除 Git 跟踪；实际目录、密码和私钥不写入项目文档。此前 main 渠道已完成 Actions 预发布及实际附件核验；正式 tag 的 Release 身份此前通过本地构建检查，尚未执行该渠道的远端发布验收，具体范围见 [验证记录](verification.md)。

构建任务仅有仓库内容读取权限，发布任务单独授予 `contents: write`，使用 GitHub 自动提供的短期 `GITHUB_TOKEN`，无需个人 Token、runner 注册凭据或网站部署凭据。工作流也在目标为 `dev` 的 Pull Request 上运行日志格式校验、分析、测试、安装器检查、Android 原生编译及两种架构的 Windows Debug 编译；PR 不读取签名 Secrets、不解析发布身份、不上传安装包或创建 Release。PR 按各自编号独立排队，新提交取消该 PR 的旧检查；dev 和 tag 的发布继续串行完成。私有仓库的托管 runner 消耗账户包含的 Actions 额度；公开仓库使用标准托管 runner 的运行时间免费，存储与其他费用按 GitHub 当前计费规则执行。

自托管 runner 的安装脚本与专用标签配置已移除。此前注册的本项目 runner 不再被此工作流选择；需要清理旧服务时，在各机器对应的 runner 目录执行 `./svc.sh stop`、`./svc.sh uninstall`，并在本仓库的 Settings → Actions → Runners 中移除对应条目。仅清理本项目专用 runner，网站及其他项目的 runner 按各自配置管理。

安装包按 `HuarunWin-版本-平台-架构.扩展名` 命名，Windows 安装版另加 `-setup`，例如 `HuarunWin-0.1.0-android-arm64-v8a.apk`、`HuarunWin-0.1.0-macos-arm64.dmg`、`HuarunWin-0.1.0-windows-amd64-setup.exe` 和 `HuarunWin-0.1.0-windows-arm64.zip`。文件名中的版本不带 tag 的 `v`，预发布使用完整版本（如 `0.1.0-pre.42`）。Release 正文保留更新日志，按 Android／Windows／macOS 分组展示带架构标签的下载徽章；Android 使用 Android 图标，macOS 使用 Apple 图标，Windows 区分 Setup／Portable，顶部使用 GitHub 图标的该 Release 下载量徽章。徽章通过 Shields.io 渲染，点击仍直达本次已上传并核对的实际附件，不使用跨版本的 latest 下载地址；图片无法显示时保留含平台、包格式和架构的替代文字。末尾保留源码提交、构建记录和校验文件说明。签名清单和校验文件共用相同版本前缀，分别以 `-android-signing.json` 和 `.sha256` 结尾，清单中的文件名与附件一致。

macOS 应用包为 `华润赢.app`，`CFBundleName`、`CFBundleDisplayName` 和 DMG 挂载卷名均为“华润赢”；打包脚本从应用的 `Info.plist` 读取实际可执行文件名。Release 附件继续沿用上述 ASCII 文件名，Bundle ID 保持 `win.huarun.huarunwin`，Hub 无需修改安装包地址格式。

Windows 的原生窗口标题及主程序 `FileDescription`、安装器 `AppName`、开始菜单／可选桌面快捷方式与卸载列表均显示“华润赢”。覆盖安装时清理旧安装器生成的两处 `HuarunWin.lnk`，避免中英文入口重复。主程序文件名仍为 `huarunwin.exe`，安装器 `AppId` 仍为 `win.huarun.huarunwin`，安装目录沿用 `%LOCALAPPDATA%\Programs\HuarunWin`；`CompanyName: win.huarun`、`InternalName`／`ProductName: huarunwin` 继续用于既有数据目录及更新身份识别。安装器的 `OriginalFilename: huarunwin-setup.exe`、`FileDescription: HuarunWin Setup` 同样保留，供已发布客户端校验。Inno 模板以带 BOM 的 UTF-8 保存中文。上述显示名调整不改变 Release 附件名称或 Hub 地址格式。

上述架构拆分从下一次构建生效，已发布的 Universal DMG／ZIP 保持原有内容；不将旧包改名冒充单架构包。正式版本已发布的安装包不会由同版本重跑替换，发布新的正式包须使用新版本。

## 版本与更新日志

客户端更新信息独立存放于公开的 [huarunwin-hub](https://github.com/huarunwin/huarunwin-hub)，读取地址固定为：

```text
https://raw.githubusercontent.com/huarunwin/huarunwin-hub/main/api/updates.json
```

`api/updates.json` 按 `release`（正式）、`debug`（测试）分别保存更新信息。以下仅为格式示例：

```json
{
  "release": {
    "publishedVersion": "0.1.0",
    "releases": [
      {
        "version": "0.1.0",
        "changes": ["首次发布"]
      }
    ]
  },
  "debug": {
    "publishedVersion": null,
    "releases": []
  }
}
```

每个渠道仅比较自己的 `publishedVersion` 与本机版本；`null` 表示该渠道尚未发布版本。非空指针必须对应唯一且有非空日志的记录。正式渠道版本使用 `X.Y.Z`，测试渠道使用 dev 包的完整版本，如 `0.1.0-pre.42`，不带 `v` 或 `+构建号`，不另存日期、tag 或发布序号。Git tag 为 `v0.1.0` 时，这里的版本仍写 `0.1.0`。提前准备的高版本记录不会触发更新；删除尚未发布版本的安装包后，应清理失效的显式下载地址，可保留该版本的预备日志，继续保留原发布指针。

每条远端版本记录的 `downloadUrl` 可省略或为 `null`，此时默认使用 `https://github.com/huarunwin/huarunwin/releases/tag/v<version>`，例如 `0.1.0` 对应 `/releases/tag/v0.1.0`。显式配置的绝对 HTTPS 地址优先；空字符串、类型错误或无效地址仍报错，不改用默认地址。点击“前往下载”后读取该确切发布页的真实附件，或使用显式安装包直链；默认规则只生成发布页地址，不构造安装包地址，也不读取 Latest 选择版本。可选 `packages` 继续按平台、架构配置真实直链和 SHA-256，各项安装包的 `downloadUrl` 仍必填。正式和测试渠道独立处理，缺少渠道、发布页或本机安装包时提示失败，不互相回退。格式、身份要求及平台行为见 [客户端自身更新](self-updating.md)。

默认地址保留完整预发布版本，不自动映射到固定 `pre`。当前 dev 构建发布在 `pre` 下，启用 Hub 测试渠道时须用显式版本安装包直链或 `packages` 绑定目标包。旧客户端仍要求顶层 `downloadUrl`，兼容这些版本时应继续提供该字段；省略规则在支持本次解析逻辑的客户端中生效。

下载由现有下载管理器处理，显示进度并支持取消、重试；完成后衔接系统安装或独立桌面更新进程。Android 保留系统覆盖安装确认，macOS／Windows／Linux AppImage 替换前明确确认退出，iOS 使用 App Store／TestFlight。自身更新不提供改包或重签入口，失败保留安装包；关闭更新页后仍可从下载管理继续安装，后台完成下载不会自行安装。此流程与第三方应用的安装助手分开。

本地 Flutter debug 运行默认使用 `debug` 渠道，release/profile 默认使用 `release`。可通过 `--dart-define=HUARUNWIN_UPDATE_CHANNEL=debug` 或 `release` 显式选择；CI 的 dev 构建选择 `debug`，正式 tag 选择 `release`，与实际采用的 release 编译优化模式独立。

正式 tag 创建前，先将对应版本的预备日志提交推送到 Hub `main` 的 `release.releases`，例如 tag `v0.1.0` 对应 `version: "0.1.0"` 和非空字符串数组 `changes`。保留原发布指针；尚未发布时保持 `publishedVersion: null`。仅在相邻仓库修改 JSON 不算完成此步骤。

在客户端仓库根目录执行前置校验，成功后才创建并推送 tag。下例使用 `v0.1.0` 展示命令，实际操作时替换为尚未使用的目标版本：

```bash
python3 tool/ci/release.py check-tag v0.1.0 &&
  git tag -a v0.1.0 -m "Release v0.1.0" &&
  git push origin refs/tags/v0.1.0
```

`check-tag` 是只读检查，校验 tag 格式及匿名读取的公开 Hub 正式渠道，不使用未推送的本地 Hub 文件替代远端。`downloadUrl` 可省略，不要求发布页或安装包在构建前已经存在；版本记录必须唯一且日志非空。网络失败、非法 JSON 或缺少记录时返回失败，不创建 tag。Actions 中的 `validate` 对正式 tag 再执行同样的检查；它能阻止构建，但不能撤销已经通过其他方式创建的 tag。

构建上传安装包并确认下载地址可匿名访问后，最后再修改 Hub 对应渠道的 `publishedVersion`。如果下载地址或 Release 尚未公开，首次发布继续保持对应渠道为 `null`，已有版本则保留原发布指针，不能把仅维护者可见的附件当作公开下载地址。Hub 不自动同步源码仓库的 Release，也不要求客户端持有 Token。

Hub `api/updates.json` 是客户端日志、发布校验及 Release 说明的唯一数据源，客户端仓库和安装包不再保存独立日志 JSON。正式 Release 说明取 `release.releases` 中与 tag 精确匹配的版本记录，不受发布指针是否已推进影响；dev 说明只取 `debug.releases` 中当前完整预发布版本的记录，尚未准备该记录时省略日志段，不使用正式渠道或基础版本日志。元数据生成及发布时匿名读取 Hub，网络或渠道数据无效时停止发布。正式编译版本取 tag，dev 版本取 `pubspec.yaml` 的基础版本及运行序号；macOS 原生版本保留数字部分，完整版本通过 `--dart-define=HUARUNWIN_VERSION=…` 写入应用。内部构建号不参与更新判断。

Release 仅上传安装包、签名清单及其校验文件，不另行上传日志快照。正式版本相同提交且附件完整时，重复发布保留既有附件与说明；已公开版本来源不符或附件不完整时停止并要求检查，改变已发布安装包需使用新版本。客户端不依赖 GitHub Latest。

应用启动静默检查一次；设置提供手动检查、实际构建版本和当前渠道的 Hub 日志。打开日志页或刷新时在线读取，预备版本标注“尚未发布”，空列表显示当前渠道暂无日志；读取失败显示错误并允许重试，不使用随包日志回退。测试渠道的更新提醒明确显示“测试版本”。检查失败不显示为“已是最新版本”，自动检查保持安静，手动检查允许重试；当前版本更高时不提示降级。

更新浮层按 FlClash 默认视觉独立实现，在所有窗口宽度下居中显示。标题 17/22 dp、版本 22/28 dp、日志 15/20 dp，最大宽度 348 dp、连续圆角 34 dp；日志可选择、可滚动。底部提供中性“取消”“本版本不再提示”和主题色“前往下载”，三个按钮不足以并排显示时依次上下排列为下载、忽略、取消。弹性入场、退出淡出及按压反馈遵循减少动画设置。取消仅关闭本次浮层，不写入忽略记录。

“本版本不再提示”按渠道保存精确版本列表到本机偏好（`appUpdates.ignoredVersions.release`／`debug`）。自动检查跳过已忽略的版本，其他版本和另一渠道不受影响；重启后保留。手动检查绕过忽略列表，仍按 `publishedVersion` 比较版本。关闭浮层不等于忽略，保存失败会提示重试，不将未成功保存的选择视为已忽略。

## 分发、许可与品牌资源

2026-10-20 仓库公开前的匿名核对中，源码仓库的 Release 页面返回 404，Hub 的 `release` 与 `debug` 发布指针均为 `null`，当时尚无可匿名下载的发布包。仓库改为公开不会自动更新 Hub；更新对应渠道指针前，仍需确认目标附件可匿名访问，并启用和核对根目录 [SECURITY.md](../SECURITY.md) 的私密报告渠道。本地文档和流水线改动不会自动完成这些远端设置。

macOS 当前使用 ad-hoc 签名，尚未配置 Developer ID 签名或 Apple 公证。[README 的常见问题排查](../README.md#常见问题排查)与包含 macOS DMG 的 Release 正文提供首次打开被拦截时的处理提示：核对来源与摘要后，仅对实际安装的应用执行 `xattr -rd com.apple.quarantine`，或按「系统设置 → 隐私与安全性」中的提示处理。命令路径须匹配该版本的真实应用名，已发布的 v0.2.0 使用 `HuarunWin.app`，中文名新构建使用 `华润赢.app`；权限不足时才使用 `sudo`。移除隔离标记不能修复真实损坏、无效签名或架构不兼容，公开源码、签名校验和文件摘要均不能替代 Apple 公证。

本项目采用根目录 [LICENSE](../LICENSE) 中的“华润赢源码查看与审计许可 1.0”，定位为源码公开（Source Available），不以开源项目名义发布。该许可允许查看、学习、安全审计、原样本地编译验证和个人使用；未经著作权人事先书面授权，不得修改、制作衍生版本或再分发源码、官方安装包及自行编译的产物。必要的本机构建配置、审计结论发表与合理代码引用、法律及托管平台保留权限的具体边界见许可正文。反馈问题和审计发现不要求取得修改授权，修改代码或提交补丁前须先取得书面授权。

项目许可仅适用于著作权人有权许可的原创内容，不缩减第三方许可证已授予的权利，也不能规避第三方许可证对组合与分发的要求。名称、Logo 和其他品牌标识不因此获得独立使用授权，原样运行与合理来源说明按许可正文处理。公开源码提供审查条件，不构成安全认证，也不保证发布安装包与公开源码一致。

根目录 `LICENSE` 作为 Flutter 资源随所有平台构建分发，在“设置 → 软件许可”中以“华润赢客户端”置顶展示全文。第三方依赖许可继续独立列出，不另存项目许可副本，避免仓库与应用内文本不一致。

视觉独立实现，参考 FlClash 的主题、留白、曲率和跨端布局方向，未复制其 GPL 组件。后续引入第三方源码时需先核对其许可与本项目授权方式是否兼容。

Android 改包名直接依赖 [ARSCLib 1.4.0](https://github.com/REAndroid/ARSCLib)，采用 Apache-2.0，完整许可与版权声明随 `assets/licenses/arsclib.txt` 分发，并注册到应用许可页。APKEditor 与 Apktool 作为实现思路参考，不嵌入其命令行工具；AppManager 仅作为重签／密钥设计参考，不复制其 GPL-3.0-or-later 源码。

应用图标与侧栏标记采用网站蓝底白色 H Logo，原始 SVG 从网站的 `public/brand/huayun-icon.svg` 原样保存到 `assets/brand/huarun-icon.svg`。在 macOS 项目根目录运行 `swift tool/create_icons.swift`，可生成 macOS／iOS／Android／Windows 图标及侧栏 PNG，无需联网或访问网站源码。macOS 保留系统图标留白，iOS 使用不透明蓝底并由系统裁切圆角。
