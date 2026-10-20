# 发布与许可

文中的命令和源码路径以仓库根目录为基准。

项目仓库统一归属 [huarunwin](https://github.com/huarunwin) GitHub 组织，维护者个人账号为 `freephilx`：[客户端源码与安装包](https://github.com/huarunwin/huarunwin)、[公共更新资源](https://github.com/huarunwin/huarunwin-hub)。

## GitHub Actions 自动打包

工作流为 [release.yml](../.github/workflows/release.yml)，打包 Android 和 macOS，使用 GitHub 标准托管 runner：

- 推送到 `main`：成功后移动固定 `pre` tag，覆盖同一个预发布 Release 的说明及安装包，不占用正式版的 Latest 标记。发布前核对 main 的最新提交，已过时的任务不覆盖 Release。
- 推送其他 tag：仅接受 `v<version>`，例如 `v1.2.3`、`v1.2.3-rc.1`；后者仍标记为预发布。tag 必须对应 `changelog.json` 中唯一且非空的版本日志，否则在安装 FVM 和 Flutter 前失败。`pre` 是自动维护的保留 tag，不触发新构建。
- 支持手动运行 main 或 tag；功能分支不发布。检查、测试、Android 签名校验和 Mac 打包全部成功后才更新 Release。安装包先上传成功，再替换旧说明、清理旧附件；上传失败保留上一版。
- main 推送与 PR 仅修改 Markdown 文档、`docs/` 资料或 `.gitignore` 时不触发工作流；`docs/privacy.md` 是随包资源，单独保留构建触发。源码、测试、构建脚本、工作流、依赖配置、资源、`LICENSE` 和 `changelog.json` 等其他文件的变更仍触发检查与编译。路径筛选不影响版本 tag 推送和手动运行。
- 产物为 Android `armeabi-v7a`、`arm64-v8a`、`x86_64` 三份 APK，macOS 的 Apple Silicon `arm64`、Intel `amd64` 两份 DMG，以及 Android 签名清单和 SHA-256 校验文件。版本 tag 还附带 `changelog.json` 快照，校验文件覆盖上述全部附件。macOS 当前使用 ad-hoc 签名，尚未配置 Developer ID 签名和 Apple 公证。
- Flutter 版本固定读取 `.fvmrc`。预发布名称为 `基础版本-pre.运行序号`，Android `versionName` 和 Dart 中的版本保留完整预发布标识，Mac 原生版本字段保持数字格式。内部构建号使用 Actions 的运行序号；Flutter 3.47.6 的 Android 分架构 APK 在该值上分别增加 1000／2000／4000，流水线验证实际版本码，升级 Flutter 时须同时复核此规则。

检查与 Android 构建固定使用 `macos-15`，Mac 构建矩阵分别使用 `macos-15`（Apple Silicon）和 `macos-15-intel`（Intel）。GitHub 镜像提供 Xcode、Python 3、CocoaPods、Homebrew 和 Android SDK；Android 任务另固定 Temurin JDK 17。工作流先校验更新日志，再通过 `brew install leoafarias/fvm/fvm` 安装 FVM，读取 `.fvmrc` 安装指定 Flutter SDK。Android 编译 Debug 应用及 instrumentation APK，确保 Kotlin、Manifest 和原生测试源码进入编译；此步骤不启动设备或运行 instrumentation 测试。Mac 每个架构独立构建，打包前核对主程序与安装助手均仅包含目标架构，并验证应用签名；DMG 中提供应用和 Applications 快捷入口，不再生成 Universal 包或 ZIP。发布任务使用 `ubuntu-24.04`，等待检查、Android 及两个 Mac 构建全部成功后，合并同次运行的构建附件、生成 SHA-256 并上传 Release。

Android 本地 Debug 构建可通过忽略的 `android/debug-signing.local.properties` 指定固定调试身份，模板见 [`debug-signing.local.properties.example`](../android/debug-signing.local.properties.example)；未配置时使用 Android 默认调试密钥。文件存在但配置无效时明确失败。本地 release 构建使用 `android/key.properties`，模板见 [`key.properties.example`](../android/key.properties.example)，缺失时不回退调试签名。两份配置与密钥、密码均不得提交。

CI 在仓库 Settings → Secrets and variables → Actions 配置两组固定身份。main 和预发布 tag 的 `debug` 更新渠道使用 `ANDROID_DEBUG_*`，正式 tag 的 `release` 渠道使用 `ANDROID_RELEASE_*`。两种渠道都采用 release 编译优化，签名按更新渠道分别选择；没有回退到另一组的逻辑。

| Debug Secret | Release Secret | 内容 |
| --- | --- | --- |
| `ANDROID_DEBUG_KEYSTORE_BASE64` | `ANDROID_RELEASE_KEYSTORE_BASE64` | 对应 keystore 文件的 Base64 内容，允许换行 |
| `ANDROID_DEBUG_KEYSTORE_PASSWORD` | `ANDROID_RELEASE_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_DEBUG_KEY_ALIAS` | `ANDROID_RELEASE_KEY_ALIAS` | 密钥别名 |
| `ANDROID_DEBUG_KEY_PASSWORD` | `ANDROID_RELEASE_KEY_PASSWORD` | 私钥密码 |
| `ANDROID_DEBUG_SIGNING_CERT_SHA256` | `ANDROID_RELEASE_SIGNING_CERT_SHA256` | 该证书的完整 SHA-256 指纹，64 位十六进制或冒号分隔格式 |

[release.py](../tool/ci/release.py) 从已经核验的发布身份导出签名前缀，工作流仅将该渠道的五项 Secrets 映射到构建脚本的通用环境变量。[android_release.py](../tool/ci/android_release.py) 在临时目录还原密钥、临时创建忽略的 `key.properties`，无论成功或失败都清理自己创建的配置，不覆盖已有本机配置。缺少对应渠道 Secrets 会阻止发布；CI 不生成替代密钥。

每份 APK 都须通过 `apksigner verify`、当前渠道的固定证书指纹、应用 ID `win.huarun.huarunwin`、完整版本名称、预期版本码及实际原生库 ABI 检查。正式 `release` 渠道额外拒绝 Android Debug 证书；`debug` 渠道只接受其已配置的精确证书，不接受任意 runner 自动生成的调试身份。公开的 `*-android-signing.json` 记录渠道、文件名、应用身份、版本、证书和文件 SHA-256，供下载者核对；其中没有私钥或密码。这些检查不代替源码与二进制一致性证明或真实覆盖升级验收。

2026-10-20 按维护者要求保留现有 Debug 证书身份，另建独立 Release 密钥，并写入仓库的上述 10 项 Actions Secrets，已核对名称齐全。两份 keystore 和仅供本机使用的 `android-signing.json` 密码配置保存在维护者指定的私有目录，权限分别为目录 700、文件 600，并排除 Git 跟踪；实际目录、密码和私钥不写入项目文档。main 渠道已完成 Actions 预发布及实际附件核验；正式 tag 的 Release 身份此前通过本地构建检查，尚未执行该渠道的远端发布验收，具体范围见 [验证记录](verification.md)。

构建任务仅有仓库内容读取权限，发布任务单独授予 `contents: write`，使用 GitHub 自动提供的短期 `GITHUB_TOKEN`，无需个人 Token、runner 注册凭据或网站部署凭据。工作流也在 `main` 的 Pull Request 上运行日志格式校验、分析、测试、安装器检查和 Android 原生编译；PR 不读取签名 Secrets、不解析发布身份、不上传安装包或创建 Release。PR 按各自编号独立排队，新提交取消该 PR 的旧检查；main 和 tag 的发布继续串行完成。私有仓库的托管 runner 消耗账户包含的 Actions 额度；公开仓库使用标准托管 runner 的运行时间免费，存储与其他费用按 GitHub 当前计费规则执行。

自托管 runner 的安装脚本与专用标签配置已移除。此前注册的本项目 runner 不再被此工作流选择；需要清理旧服务时，在各机器对应的 runner 目录执行 `./svc.sh stop`、`./svc.sh uninstall`，并在本仓库的 Settings → Actions → Runners 中移除对应条目。仅清理本项目专用 runner，网站及其他项目的 runner 按各自配置管理。

安装包按 `HuarunWin-版本-平台-架构.扩展名` 命名，例如 `HuarunWin-0.1.0-android-arm64-v8a.apk`、`HuarunWin-0.1.0-android-armeabi-v7a.apk`、`HuarunWin-0.1.0-android-x86_64.apk`、`HuarunWin-0.1.0-macos-arm64.dmg` 和 `HuarunWin-0.1.0-macos-amd64.dmg`。文件名中的版本不带 tag 的 `v`，预发布使用完整版本（如 `0.1.0-pre.42`）。Release 正文提供更新日志与按平台、架构排列的真实附件下载链接，末尾保留源码提交、构建记录和校验文件说明，不再重复展示版本、内部构建号或签名配置细节。签名清单和校验文件共用相同版本前缀，分别以 `-android-signing.json` 和 `.sha256` 结尾，清单中的文件名与附件一致。

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
        "downloadUrl": "https://github.com/huarunwin/huarunwin/releases/tag/v0.1.0",
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

每个渠道仅比较自己的 `publishedVersion` 与本机版本；`null` 表示该渠道尚未发布版本。非空指针必须对应唯一且有非空日志的记录。版本使用三段语义化版本，可带 `-beta.1`、`-rc.1` 等预发布标识，不带 `v` 或 `+构建号`，不另存日期、tag 或发布序号。提前准备的高版本记录不会触发更新。

每条远端版本记录必须有独立的 HTTPS `downloadUrl`。点击“前往下载”后进入应用内更新页：读取该地址指向的确切 GitHub Release 的真实附件，或使用直接安装包地址，不根据 tag、版本或仓库名拼接地址，不读取 Latest 选择版本。也可通过可选的 `packages` 按平台、架构明确配置直链和 SHA-256，便于迁移下载来源。正式和测试渠道可使用不同下载地址；渠道缺失、地址错误或未提供本机安装包时提示失败，不互相回退。格式、身份要求及平台行为见 [客户端自身更新](self-updating.md)。

下载由现有下载管理器处理，显示进度并支持取消、重试；完成后衔接系统安装或独立桌面更新进程。Android 保留系统覆盖安装确认，macOS／Windows／Linux AppImage 替换前明确确认退出，iOS 使用 App Store／TestFlight。自身更新不提供改包或重签入口，失败保留安装包；关闭更新页后仍可从下载管理继续安装，后台完成下载不会自行安装。此流程与第三方应用的安装助手分开。

本地 Flutter debug 运行默认使用 `debug` 渠道，release/profile 默认使用 `release`。可通过 `--dart-define=HUARUNWIN_UPDATE_CHANNEL=debug` 或 `release` 显式选择；CI 的 main 构建和预发布 tag 选择 `debug`，正式 tag 选择 `release`，与实际采用的 release 编译优化模式独立。

发布时先准备记录、上传安装包并确认下载地址可匿名访问，最后再修改 Hub 对应渠道的 `publishedVersion`。如果下载地址或 Release 尚未公开，保持对应渠道为 `null`，不能把仅维护者可见的附件当作公开下载地址。Hub 不自动同步源码仓库的 Release，也不要求客户端持有 Token。

根目录 [changelog.json](../changelog.json) 保留随安装包提供的本地日志和 tag 编译校验，结构仍为 `publishedVersion`、`releases`，每条包含 `version` 和 `changes`。该本地指针不参与在线更新判断。版本 tag 必须对应其中唯一且非空的版本日志，否则在安装 FVM 和 Flutter 前失败；所有构建检查文件格式。编译版本和 Release 说明从 tag 匹配的记录取得，macOS 原生版本保留数字部分，完整版本通过 `--dart-define=HUARUNWIN_VERSION=…` 写入应用。内部构建号不参与更新判断。

版本 tag 的 Release 继续附带本地 `changelog.json` 快照及其 SHA-256，固定 `pre` 构建不上传这份快照。客户端不读取该附件，也不依赖 GitHub Latest。正式版本相同提交的重复发布保留既有附件，改变内容需发布新版本。

应用启动静默检查一次；设置提供手动检查、实际构建版本和本地日志。测试渠道的更新提醒明确显示“测试版本”。检查失败不显示为“已是最新版本”，自动检查保持安静，手动检查允许重试；当前版本更高时不提示降级。

更新浮层按 FlClash 默认视觉独立实现，在所有窗口宽度下居中显示。标题 17/22 dp、版本 22/28 dp、日志 15/20 dp，最大宽度 348 dp、连续圆角 34 dp；日志可选择、可滚动。底部提供中性“取消”“本版本不再提示”和主题色“前往下载”，三个按钮不足以并排显示时依次上下排列为下载、忽略、取消。弹性入场、退出淡出及按压反馈遵循减少动画设置。取消仅关闭本次浮层，不写入忽略记录。

“本版本不再提示”按渠道保存精确版本列表到本机偏好（`appUpdates.ignoredVersions.release`／`debug`）。自动检查跳过已忽略的版本，其他版本和另一渠道不受影响；重启后保留。手动检查绕过忽略列表，仍按 `publishedVersion` 比较版本。关闭浮层不等于忽略，保存失败会提示重试，不将未成功保存的选择视为已忽略。

## 分发、许可与品牌资源

2026-10-20 仓库公开前的匿名核对中，源码仓库的 Release 页面返回 404，Hub 的 `release` 与 `debug` 发布指针均为 `null`，当时尚无可匿名下载的发布包。仓库改为公开不会自动更新 Hub；更新对应渠道指针前，仍需确认目标附件可匿名访问，并启用和核对根目录 [SECURITY.md](../SECURITY.md) 的私密报告渠道。本地文档和流水线改动不会自动完成这些远端设置。

macOS 当前使用 ad-hoc 签名，尚未配置 Developer ID 签名或 Apple 公证。首次打开可能触发系统拦截，请按「系统设置 → 隐私与安全性」中的提示处理；公开源码、签名校验和文件摘要均不能替代 Apple 公证。

本项目采用根目录 [LICENSE](../LICENSE) 中的“华润赢源码查看与审计许可 1.0”，定位为源码公开（Source Available），不以开源项目名义发布。该许可允许查看、学习、安全审计、原样本地编译验证和个人使用；未经著作权人事先书面授权，不得修改、制作衍生版本或再分发源码、官方安装包及自行编译的产物。必要的本机构建配置、审计结论发表与合理代码引用、法律及托管平台保留权限的具体边界见许可正文。反馈问题和审计发现不要求取得修改授权，修改代码或提交补丁前须先取得书面授权。

项目许可仅适用于著作权人有权许可的原创内容，不缩减第三方许可证已授予的权利，也不能规避第三方许可证对组合与分发的要求。名称、Logo 和其他品牌标识不因此获得独立使用授权，原样运行与合理来源说明按许可正文处理。公开源码提供审查条件，不构成安全认证，也不保证发布安装包与公开源码一致。

根目录 `LICENSE` 作为 Flutter 资源随所有平台构建分发，在“设置 → 软件许可”中以“华润赢客户端”置顶展示全文。第三方依赖许可继续独立列出，不另存项目许可副本，避免仓库与应用内文本不一致。

视觉独立实现，参考 FlClash 的主题、留白、曲率和跨端布局方向，未复制其 GPL 组件。后续引入第三方源码时需先核对其许可与本项目授权方式是否兼容。

Android 改包名直接依赖 [ARSCLib 1.4.0](https://github.com/REAndroid/ARSCLib)，采用 Apache-2.0，完整许可与版权声明随 `assets/licenses/arsclib.txt` 分发，并注册到应用许可页。APKEditor 与 Apktool 作为实现思路参考，不嵌入其命令行工具；AppManager 仅作为重签／密钥设计参考，不复制其 GPL-3.0-or-later 源码。

应用图标与侧栏标记采用网站蓝底白色 H Logo，原始 SVG 从网站的 `public/brand/huayun-icon.svg` 原样保存到 `assets/brand/huarun-icon.svg`。在 macOS 项目根目录运行 `swift tool/create_icons.swift`，可生成 macOS／iOS／Android／Windows 图标及侧栏 PNG，无需联网或访问网站源码。macOS 保留系统图标留白，iOS 使用不透明蓝底并由系统裁切圆角。
