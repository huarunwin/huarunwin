# 客户端自身更新

在线版本唯一来源为 [Hub 的 api/updates.json](https://github.com/huarunwin/huarunwin-hub/blob/main/api/updates.json)。只比较当前 `release`／`debug` 渠道的 `publishedVersion`，日志展示、tag 前置校验及 Release 说明也只读取该 Hub 文件。更新提醒和忽略规则见 [发布与许可](releasing.md)。

客户端获取该 Raw 文件及 GitHub 安装包时遵循独立的“GitHub 加速”设置，可通过 GH-Proxy 转发同一原始地址；Raw 与下载分别记录回退状态。此设置不改变 Hub 数据格式、渠道、发布指针和附件解析规则，版本详情 HTML 仍直连 GitHub。手动检查更新或刷新日志优先重试 Raw 直连；详情见[GitHub 加速](content-sources.md#github-加速)。

## 安装包配置

每版本 `downloadUrl` 可省略或为 `null`，此时使用 `https://github.com/huarunwin/huarunwin/releases/tag/v<version>`，例如 `0.2.0` 对应 `/releases/tag/v0.2.0`。显式配置继续优先，可使用确切发布页或本机可识别的安装包直链。GitHub 发布页仍仅解析其真实附件 HTML，不读取 Latest 或自行构造附件地址；发布页不存在或缺少本机安装包时明确失败。多个候选按系统架构和格式推荐，只有唯一且架构已知的推荐包才直接开始下载，否则由用户选择并确认。未知架构不声称兼容。

建议在每个远端版本添加可选的 `packages` 数组，明确区分平台、架构和下载地址。以下是单条版本记录的格式示例，域名与版本仅用于展示格式，不能原样当作已发布内容：

```json
{
  "version": "0.2.0",
  "changes": ["更新说明"],
  "packages": [
    {
      "platform": "Android",
      "architecture": "arm64",
      "kind": "apk",
      "downloadUrl": "https://downloads.example.com/0.2.0/huarunwin-arm64.apk"
    }
  ]
}
```

- 版本记录顶层的 `downloadUrl` 为可选字段；省略或 `null` 使用默认发布页，空字符串、错误类型、非 HTTPS 或带用户名密码的显式地址仍被拒绝。默认地址保留完整版本，包括预发布后缀，不自动改为 `pre`；当前 dev 测试包需通过显式版本安装包直链或 `packages` 指向真实资源。兼容尚不支持默认地址的旧客户端时，继续提供顶层 `downloadUrl`。
- `packages` 内每份安装包的 `downloadUrl` 仍须是绝对 HTTPS 地址，不带用户名或密码，不使用发布页默认规则。各渠道、版本及安装包可分别迁移地址；同一固定 URL 的不同目标版本也创建独立任务。顶层地址省略时，安装包的来源记录使用解析后的默认发布页。
- 有 `packages` 时只从该数组选包，不回退到其他平台、渠道或旧版本。每项非 iOS 安装包须提供架构：`arm64`、`armv7`、`x64`、`x86`、`universal`。`universal` 必须确实包含相应架构。
- 可选 `sha256` 是安装包的真实 64 位十六进制 SHA-256。建议为所有包提供；未配置 `packages` 而从 GitHub 发布页读取附件时，也会使用 HTML 中公开且能唯一绑定该附件的摘要。AppImage 自身替换必须具有这两种来源之一的公开摘要；显式 `packages` 中的 AppImage 须配置 `sha256`。
- iOS 使用 `platform: "iOS"`、`kind: "store"`，无需架构；每版本每渠道只允许一个 App Store 或 `https://testflight.apple.com/join/...` 地址。不能配置 IPA 或任意网页冒充系统更新渠道。
- 版本日志、链接和摘要统一在公开 Hub 维护。先准备版本日志，再构建上传安装包并确认匿名可用，最后才修改发布指针；安装包信息必须对应实际构建产物。

## 平台安装方式

| 平台 | 接受格式 | 更新方式与身份检查 |
| --- | --- | --- |
| Android | APK | 核对真实包名、精确版本名称、APK 实际签名及当前签名证书，保留版本码降级、ABI、最低系统及摘要检查；经来源安装授权和系统最终确认覆盖安装 |
| macOS | DMG、ZIP | 提取唯一应用，核对 `win.huarun.huarunwin`、完整版本与渠道、系统架构和签名；独立安装助手待客户端退出后从同卷暂存目录原子交换应用，保留旧包并重新打开 |
| Windows | ZIP、EXE、MSI、MSIX | 独立 PowerShell 进程先核对摘要、程序／安装包身份、版本及签名，准备成功后才请求客户端退出；ZIP 备份并替换 Flutter 运行文件后重新打开，其他格式继续系统安装界面 |
| Linux | AppImage、DEB、RPM、`.pkg.tar.zst` | AppImage 验证 ELF／AppImage 标记、架构及公开摘要，仅替换从 `APPIMAGE` 环境所指的普通文件启动的当前客户端；系统包核对包名 `huarunwin` 与版本后交给系统软件包工具 |
| iOS | App Store／TestFlight | 打开配置的该应用系统更新渠道，由系统完成更新；不在应用内下载或安装 IPA |

Android 自身更新只接受与当前客户端相同的一组签名证书，不自动重签、改包或卸载；当前实现不处理签名密钥轮换谱系。更新成功可能导致旧进程被系统终止，未收到明确系统成功回调的记录仍为未确认，不通过包名存在推断本次成功。

Android CI 按更新渠道使用两份固定密钥：dev 预发布使用 Debug 身份，正式 tag 使用独立 Release 身份。Debug 沿用迁移前的证书，后续同渠道构建保持身份；不同证书的 Debug 与 Release 不能直接互相覆盖安装。APK 的 `versionName` 保留与 Hub 记录相同的完整版本，包括 `-pre.…` 等后缀。`*-android-signing.json` 提供每份真实 APK 的版本码、证书指纹和文件摘要；Hub 的安装包链接及摘要仍需按实际公开产物配置，流水线不自动修改 Hub 指针。

macOS 的 `CFBundleShortVersionString` 保持纯数字。构建阶段从与 Dart 相同的 `HUARUNWIN_VERSION`／`HUARUNWIN_UPDATE_CHANNEL` 生成 `Contents/Resources/huarunwin-build.plist`，随后纳入应用签名，原生安装助手据此校验完整预发布版本与渠道；缺少此资源的旧包不能作为自身更新目标。无显式定义时采用 Flutter 版本和实际 Debug／其他构建模式。当前 ad-hoc 构建可以继续采用有效 ad-hoc 签名；当前客户端已有开发者签名时更新包须同 Team ID，不降级到 ad-hoc。目标目录不可写时通过系统管理员授权启动独立助手，重启应用前恢复原用户身份。

macOS 新构建使用 `华润赢.app`，应用身份仍为 `win.huarun.huarunwin`。自身更新按当前运行应用的实际路径替换，因此旧安装若为 `HuarunWin.app`，更新后仍保留该文件名；改名不附带安装路径迁移。

Windows ZIP 应包含唯一的 `huarunwin.exe`、`flutter_windows.dll` 和 `data/flutter_assets`，可带同目录插件 DLL；只替换主程序、DLL 与 data，在程序同卷目录保存旧文件备份，失败尝试恢复。程序版本资源的 `CompanyName` 为 `win.huarun`，`InternalName`／`ProductName` 为 `huarunwin`，`ProductVersion`（忽略 `+` 构建元数据）须匹配完整目标版本。EXE 使用 Inno Setup 安装器，版本资源字段仅去掉编译器填充的尾部 ASCII 空格后，厂商、产品名及完整文本版本仍须精确匹配；安装器身份另以 `OriginalFilename: huarunwin-setup.exe` 和 `FileDescription: HuarunWin Setup` 核对，不将 Inno 的内部名称当作主程序名称。便携 ZIP 中的主程序继续严格检查 `InternalName: huarunwin`。MSI 要求 `ProductName: huarunwin`、`Manufacturer: win.huarun`；MSIX 要求身份 `win.huarun.huarunwin`，系统包的数字版本须匹配目标基础版本。当前程序已有有效 Authenticode 签名时，新包须有效且证书指纹相同。便携构建发布完整 ZIP，不用单个裸 EXE 替代运行目录；安装器交接成功仅记为结果未确认。当前脚本通过 Windows 自带的 Windows PowerShell 运行，写出 UTF-8 BOM 保留中文脚本编码。

Linux 系统包需要本机相应的 `dpkg-deb`／`rpm`／`bsdtar` 读取身份，随后通过系统桌面工具安装，保留权限确认，不执行 root shell。AppImage 备份原文件并在原目录原子替换；目录不可写或当前客户端不是 AppImage 启动时明确失败，不猜测其他安装路径。AppImage 的来源身份依赖受信任 Hub／发布页提供的摘要，不声称 ELF 标记本身能证明应用身份。

macOS 在 `/Applications` 内更新时复用已启用的管理员助手；尚未启用且目录不可写时首次由系统授权安装助手。替换成功后迁移客户端签名信任，常驻助手代码保持原授权版本。开发目录等可写位置继续普通权限更新，其他提权位置拒绝并提示移到“应用程序”；手动换签名或升级助手实现可能需在操作中重新确认系统授权。详见[管理员助手](installation.md#mac-管理员助手)。此改动不更改 Hub 的更新字段、版本、渠道或下载地址。

## 交互与恢复

下载复用应用内管理器，保留进度、取消和重试。下载页仍在前台时，完成后自动衔接安装；macOS、Windows、Linux AppImage 在准备和替换前提供“取消／退出并安装”确认。确认之后先准备独立安装进程，准备失败则继续运行当前客户端。另有下载时，退出确认会说明其他下载将被中断，重启后可重试。

关闭更新页后，下载可继续，完成后不主动退出或弹出安装；用户从下载管理点击“安装更新”继续。自身更新记录与第三方应用任务分开，不提供改包重签或第三方应用手动安装入口。安装前再次校验文件摘要、当前渠道及版本，旧于当前客户端的包被拒绝；来源授权返回后 Android 再校验文件与签名。

准备前和退出前均等待下载记录写入成功；保存失败取消退出并保留安装包。桌面进程用独立目录保存准备、取消、成功、错误及备份路径，重新启动或刷新下载管理时读取结果；只有明确写出的成功结果才标记完成。Windows ZIP 恢复失败会在错误中保留备份目录供手动恢复。备份不自动删除，用户确认新版可用后可按记录路径自行清理；删除下载任务不会卸载已安装客户端或删除这些恢复备份。

## 验证范围

2026-10-20 CI 已完成 main 的 Android 固定 Debug 签名与 macOS Universal 预发布，实际附件的身份、版本、架构、签名及摘要检查通过；正式 tag 的独立 Release 身份尚未执行远端发布验收。接入平台安装逻辑及私有仓库预发布不等于已有公开包。2026-10-19 已通过更新检查、忽略记录、选包、下载校验、恢复及界面交互测试；macOS 独立助手在临时应用上实际完成稳定版与预发布版的退出、替换、备份和重新启动。2026-10-20 Windows PowerShell 实际执行生产脚本，在自制临时程序上完成 ZIP 准备、等待退出、替换、备份、重启、取消、校验拒绝及文件占用回滚，共 8 项检查通过。Hub 两个渠道目前均未发布，尚未完成公开安装包的在线端到端升级。每次验证的具体范围见 [验证记录](verification.md)，Windows 安装器格式及签名升级、Linux／iOS 仍需各自系统的实际更新与恢复验收。

### 本地复验

只有明确要求测试时运行。更新逻辑与界面检查使用项目指定 SDK：

```sh
fvm flutter test test/app_updates_test.dart test/self_update_test.dart test/app_update_ui_test.dart
python3 -m unittest discover -s tool/ci -p 'test_*.py'
```

macOS 原生助手验收：

```sh
python3 tool/check_self_update.py
```

脚本以普通用户编译生产安装助手，在临时目录创建无窗口的测试应用，检查替换、重启、取消、身份／渠道／版本／签名拒绝和多实例保护。结束后清理测试应用、备份及 LaunchServices 登记；不替换已安装客户端，不请求管理员权限，不更改 Hub。

Windows 原生 ZIP 更新验收（需 Visual Studio C++ 桌面工具）：

```powershell
python tool/check_windows_self_update.py
```

脚本编译无窗口的自制程序，用 Windows 自带的 Windows PowerShell 执行生产更新脚本，检查退出前不替换、正常替换与重启、取消、摘要／版本／结构／路径拒绝，以及目录子文件和运行库占用后的保留与回滚。测试进程结束后清理，夹具、备份和报告保留在忽略的 `build/windows-self-update-qa/` 唯一目录；不替换已安装客户端、不安装第三方软件、不更改 Hub，也不验证 Authenticode 证书升级或 EXE／MSI／MSIX 自更新。

Android 原生校验可用独立测试包名运行，避免覆盖现有客户端。在已连接的测试设备上执行：

```sh
cd android
./gradlew --init-script ../tool/android_update_qa.init.gradle \
  :app:connectedDebugAndroidTest -Ptarget-platform=android-arm64 \
  -Pandroid.testInstrumentationRunnerArguments.class=win.huarun.huarunwin.ApkInstallerTest,win.huarun.huarunwin.IncomingApksTest
```

按本机配置设置 `JAVA_HOME` 和 `ANDROID_SERIAL`，其他架构相应修改 `target-platform`。正向用例要求该 QA 包没有来源安装授权；测试拦截系统界面请求，仅模拟拒绝授权，不执行真实覆盖安装。测试结束只卸载本轮专用的 `win.huarun.huarunwin.updateqa` 和 `win.huarun.huarunwin.updateqa.test`，保留正常客户端与其数据。
