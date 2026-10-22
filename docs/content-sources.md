# 内容来源与静态镜像

## 设置与行为

设置 → 应用目录 → 内容来源提供四个选项：

| 选择 | 行为 |
| --- | --- |
| 自动（默认） | 首次依次尝试华润赢网站、GitHub Raw、jsDelivr；连接失败、超时、HTTP 429 或 5xx 时尝试下一来源。回退成功后优先使用该来源 2 小时，期间其余来源沿上述顺序各尝试一次。到期后的下一次联网加载或用户手动刷新重新从网站开始，并在设置中显示最近成功来源。 |
| 华润赢网站 | 固定从 `https://huarun.win/` 获取内容，不自动转向镜像。 |
| GitHub 镜像 | 固定从公开仓库的 Raw 地址获取内容，不自动切换。 |
| jsDelivr 镜像 | 固定通过 `cdn.jsdelivr.net` 获取同一公开仓库的内容，不自动切换。 |

目录、详情及分页 HTML 的每个来源请求最多等待 5 秒，覆盖请求准备、连接、重定向和响应接收；连接与发送阶段各设 3 秒超时。自动模式下发生可切换的错误或达到总时限后，取消当前请求并立即尝试下一来源，不增加等待或重复重试；三个来源都无响应时，网络等待合计约 15 秒，随后显示已有缓存或错误。该时限不包含缓存读取及后续 HTML 解析，也不适用于图片、GitHub Release 版本选择或安装包下载。固定来源同样使用每次 5 秒上限，但不会自动切换。

2 小时从一次回退成功解析时起算，期间继续成功读取同一来源不会延长保持时间；来源及起算时间一起保存在本机，重启后沿用剩余时间。到期不启动后台探测、不丢弃仍有效的内容缓存，下一次实际需要联网获取 HTML 时再按“网站 → GitHub Raw → jsDelivr”尝试。网站恢复则继续优先网站，仍需回退则重新开始 2 小时；保持期内当前来源失败仍可立即切换。旧记录缺少起算时间、时间无效或系统时钟回拨时，下次联网从网站开始。

用户主动刷新应用目录、详情、公开栏目或应用库时，即使仍在保持期也立即从网站重试；同一次应用库刷新中的版本详情检查复用已经得到的来源结果，不对每份详情重复重置保持期。固定来源不受这一重试策略影响。显式切换来源会清除保持期，切回自动后从网站开始。缓存读取、站内图片加载和正常浏览不会主动重置保持期；请求保存来源选择代次，手动刷新或恢复尝试前的迟到结果不能改回旧优先来源或重新延长保持期。

选择保存在本机。切换后重新加载目录、详情及站内图片，保留导航、搜索、筛选与下载任务。隐藏栏目的旧结果失效，重新进入时按新来源获取。固定来源暂时不可用时，保留该来源可用的缓存并提示重试；没有缓存时显示错误。自动模式将 TLS 握手期间对端断开连接（Dart 的 `Connection terminated during handshake`，无底层 TLS 错误码）视为连接失败并尝试另一来源；404、页面结构异常、证书校验失败及其他 TLS 错误仍不切源，以免把镜像缺页或不可识别的响应掩盖成成功。

GitHub 与 jsDelivr 镜像读取同一份一次性静态快照，内容可能晚于网站。jsDelivr 对 `main` 分支有独立 CDN 缓存，内容更新可能晚于 Raw，客户端刷新不会清除 CDN 缓存。选择镜像不会使购买、账号、纠错、第三方下载等在线服务转由镜像提供，也不保证任何网络环境下都可访问。

## 地址与缓存

镜像仓库：[huarunwin/huarunwin-static](https://github.com/huarunwin/huarunwin-static)。未启用 GitHub Pages，客户端通过 HTTP 获取 HTML 原文并使用现有 DOM 解析器，不执行 JavaScript、不新增内容 API 或独立内容 JSON。

| 网站地址 | GitHub Raw 请求 | jsDelivr 请求 |
| --- | --- | --- |
| `https://huarun.win/` | `https://raw.githubusercontent.com/huarunwin/huarunwin-static/main/index.html` | `https://cdn.jsdelivr.net/gh/huarunwin/huarunwin-static@main/index.html` |
| `https://huarun.win/apps/flclash` | `https://raw.githubusercontent.com/huarunwin/huarunwin-static/main/apps/flclash.html` | `https://cdn.jsdelivr.net/gh/huarunwin/huarunwin-static@main/apps/flclash.html` |
| `https://huarun.win/jichang` | `https://raw.githubusercontent.com/huarunwin/huarunwin-static/main/jichang.html` | `https://cdn.jsdelivr.net/gh/huarunwin/huarunwin-static@main/jichang.html` |

站内图片在各镜像根地址后保留原路径，逐段编码中文与空格。两个镜像的 HTML 响应均允许 `text/html` 或 `text/plain`，响应地址须与所请求的镜像地址一致；模型与 DOM 解析器不因传输来源改变。

内容模型与解析基准始终使用原网站 URL，保留站内链接、查询参数、锚点及原始下载／购买地址。镜像只改变公开 HTML 和站内图片的传输地址，不把 Raw 或 jsDelivr 地址用于分享、购买、下载、纠错或外部网页访问。外部图片不改写。站内图片优先跟随当前成功来源，自动模式的单张图片加载失败后按网站、GitHub Raw、jsDelivr 的顺序尝试剩余来源，每个地址最多尝试一次，不修改全局来源偏好或保持时间。

网站缓存沿用原路径，GitHub Raw 与 jsDelivr 的 HTML 缓存分别位于内容目录的 `github/` 和 `jsdelivr/` 子目录；内存缓存也包含来源标识，旧网站与 GitHub 缓存保持兼容。图片按实际请求 URL 缓存。显式切换递增修订号并取消旧请求，异步解析与界面加载检查修订号／代次，旧请求不能回写当前页面。客户端缓存有效期仍为 30 分钟；刷新失败时提示正在展示上次保存的内容。

实现主要位于 `lib/services/content_sources.dart`、`lib/data/repository.dart`、`lib/services/app_controller.dart`、`lib/ui/content_image.dart` 和 `lib/ui/settings.dart`。客户端自身版本更新仍独立读取 `huarunwin-hub`，不随内容来源切换。

## 2026-10-21 一次性快照

本次通过匿名 HTTPS 请求抓取网站已经公开的页面和引用资源，不从本地旧构建产物复制内容、不执行网页脚本、不读取数据库。旧路由清单仅用来补充候选 URL；每个收录文件均重新从线上读取。

- 抓取窗口：2026-10-21 02:33:39 至 02:39:38 UTC（北京时间 10:33:39 至 10:39:38）。
- 收录：2,948 个 HTML 页面、1,345 个资源文件，共 367,821,861 字节，约 351 MiB。
- 28 个候选地址已返回 404，未收录；已识别的站内引用资源全部获取成功。
- 首页、VPS、机场、动态、人物和文章目录再次获取后，去掉脚本与预加载标记的正文 DOM 与快照一致。原始响应因脚本部分不同而无法逐字节视作同一构建；快照不宣称具备原子一致性。
- 仅公开页面及资源进入镜像，不包含网站源码、后台、私有构建产物、源码映射或访问凭据；原有第三方内容权利及许可保持不变，不将整个镜像统一宣称为开源。

本次没有修改网站打包、部署或同步脚本，也没有配置自动同步。后续刷新镜像需要另行生成和提交经过核对的公开快照；当前网站更新不会自动反映到镜像。镜像维护与客户端代码提交是两个独立仓库的操作。
