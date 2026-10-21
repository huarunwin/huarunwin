# README 预览图

[返回文档索引](../README.md)

## 图片与来源

| 文件 | 用途 |
| --- | --- |
| [preview.png](preview.png) | 浅色主题的桌面与 Android 设备组合展示 |
| [preview-dark.png](preview-dark.png) | 深色主题的桌面与 Android 设备组合展示 |

根目录 README 使用 `<picture>` 的 `prefers-color-scheme` 选择对应图片，不支持主题切换的阅读器回退到浅色图。

2026-10-20 以本项目实际运行的 macOS 与 Android 应用目录截图、现有品牌图标为输入，使用内置 imagegen 生成设备外框、背景与展示构图。画面为产品展示图；细小文字可能因生成处理与实际截图有差异，不作为运行验证、安全认证或安装包与源码一致的证明。界面内容及应用数量仅代表截图时的状态。

2026-10-22 将两张预览图中笔记本右下角的 Stash 应用卡片替换为 Surge，沿用静态内容中的 Surge 图标与应用资料，其他设备、卡片和布局保持不变。

布局参考 [FlClash 中文 README](https://github.com/chen08209/FlClash/blob/main/README_zh_CN.md) 的居中介绍和桌面／手机组合形式，未将其图片用作生成输入。图中的第三方应用图标与名称保留各自权利，项目品牌与许可见根目录 [LICENSE](../../LICENSE)。

## 生成提示词

两张图片使用相同基础提示词，并分别追加浅色或深色要求。输入顺序为对应主题的桌面截图、Android 截图及项目品牌图标；原始采集文件仅存于本地忽略目录，不写入个人设备或环境信息。

### 基础提示词

```text
Create a polished landscape GitHub README product hero image for HuarunWin (华润赢), approximately 2400 x 1500 pixels. A slim modern laptop occupies the left and middle; a front-on Android phone stands in the lower right foreground and overlaps only a small part of the laptop. Both devices rest on the same surface, fully visible, with generous clean margins and subtle realistic shadows. Camera straight on, minimal perspective, crisp restrained product photography, no people, props, large captions, watermarks, or promotional claims.

Input image 1 is the real HuarunWin desktop screenshot; use it as the laptop screen texture. Input image 2 is the real HuarunWin Android screenshot; use it as the phone screen texture. Input image 3 is the brand icon, only for identity reference. The screen contents must retain the screenshots' actual Chinese UI, sidebar, navigation, app names, icons, cards, buttons, proportions, and blue brand accents. Treat these screenshots as immutable screen textures to place inside the displays, rather than designing a new UI. Keep full screenshots visible with their original aspect ratios. Do not invent an app dashboard, statistics, new buttons, text, or features. Remove only the purple screen-sharing overlay in the desktop screenshot's top-left corner and any mouse pointer / pointer glow. No personal paths, accounts, serial numbers, or system desktop are to be added.

Show a thin, elegant neutral metal laptop with a black bezel, and a dark graphite Android phone with rounded corners and a tiny centered camera hole. No Apple logo or other hardware branding. Device frames and the studio background are presentation mockups; prioritize clear authentic application screens over decorative effects. The laptop and phone must be large enough that the layout of both UIs is legible at README width.
```

### 浅色追加要求

```text
LIGHT VERSION: use the supplied light-theme screenshots unchanged. Very light cool gray studio background (#F4F7FB), silver laptop, soft white light, subtle pale blue ambient glow. Bright, clean and quiet.
```

### 深色追加要求

```text
DARK VERSION: use the supplied dark-theme screenshots unchanged. Deep charcoal studio background (#101318), graphite metal laptop, subtle dark gray surface and gentle blue rim lighting. Quiet and elegant; no neon glow. The blue app accents stay recognizable.
```
