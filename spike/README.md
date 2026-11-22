# Worrd 入口 spike

目的只有一个：**验证三种取词入口在真机上是否可用、手感如何**。词典查询、浮窗、入库都不是这一版的重点。

## 构建 / 安装

```bash
cd spike
make install          # 生成工程、构建、装到 ~/Applications/Worrd.app
open ~/Applications/Worrd.app
```

菜单栏会出现一个书本图标。应用是 `LSUIElement`，不占 Dock。

## 主入口：Spotlight

`⌘Space` → 输入 `worrd://theme` → 回车 → 浮窗。

URL scheme 已注册，Spotlight 回车会把整串交给 App。没有实时预览是 Spotlight 的限制，输入期间不会显示释义。

已确认可用的写法：

```
worrd://theme
worrd://lookup?q=serendipity
worrd://主题
worrd://view/wordbook     # 打开单词本窗口
```

## 已验证

| 入口 | 状态 | 证据 |
|---|---|---|
| `worrd://` URL scheme | ✅ 通过 | `open "worrd://theme"` → 浮窗弹出，日志 `url event: worrd://theme -> theme` |
| 系统服务 Services | ✅ 通过 | `NSPerformService("用 Worrd 查词", …)` 返回 true，日志 `service: ubiquitous` |
| App Intent | ⚠️ 非主入口 | 元数据已生成，但运行时报 `com.apple.linkd.autoShortcut` 连接失败，Spotlight 里未必可见；当前不依赖它 |

## 图标

- 源图：`icon/icon-universal.jpeg`（2048×2048）
- 资源：`Worrd/Assets.xcassets/AppIcon.appiconset`（16/32/128/256/512 + @2x，共 10 张）
- 构建：`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`，Info.plist 里 `CFBundleIconName = AppIcon`

**注意**：macOS 26 起系统会自己给 App 图标套圆角、加投影。所以资源要用**满幅方形**（不要自带圆角和透明边距），否则会出现“系统圆角 + 自己圆角”的双层方块。第一版用了 824/1024 的内缩圆角，在 Dock 里就是双层；改成满幅后正常。

## 浮窗

- 自定义纸张色（浅色 #FCFBF8 / 深色 #20201F），16pt 圆角 + 细描边，不再依赖系统毛玻璃
- 词头 New York 衬线，音标拆英/美两栏；词性单独一列（`n.` `v.` `名`），义项在其右侧
- `①` `②` 义项、`▸` 例句分层，配色全部来自 `Theme.swift` 的 Palette
- 高度按内容估算（330–660），随 AI 补注出现/失败自动伸缩
- 底部显示「已加入单词本 · 第 N 次查询 · 上次 …」

## AI 兜底

牛津词典查不到时，如果配了 AI key，会自动改走 AI 生成词条：

- 面板先显示「牛津词典未收录 · 正在请 AI 生成释义…」
- AI 按 `HEADWORD / PHONETIC / POS / SENSE / EXAMPLE` 行格式返回，解析成和词典一致的结构
- 面板右上角标 **AI 释义**，底部标「AI 生成 · 仅供参考」，不会伪装成牛津释义
- 同样入库，`words.source = 'ai'`，单词本里带琥珀色 `AI` 标签
- 支持英文和中文查询（中文会给出英文对应词 + 例句）
- AI 没有配置时，仍然只显示「未收录」并提示去设置里填 key

## AI 补注

配置在 `~/Library/Application Support/Worrd/config.json`（权限 600），也可以从菜单栏 → 设置… 填：

```json
{
  "ai": {
    "enabled": true,
    "baseURL": "https://api.deepseek.com/v1",
    "model": "deepseek-chat",
    "apiKey": "sk-..."
  }
}
```

任何 OpenAI 兼容接口都行（DeepSeek、OpenAI、本地 Ollama 的 `/v1`）。key 为空时 AI 区块不显示，词典释义照常。

## 自定义 URL 前缀

macOS 只允许 App 声明 Info.plist 里写死的 URL scheme，运行时无法直接注册新的。所以自定义前缀采用**转发器**方案：

- 设置里填一个前缀（如 `newworrd`）→ 在 `~/Applications/WorrdAliases/` 生成一个极小的 AppleScript 转发 App
- 转发 App 声明 `newworrd://`，收到后把 URL 改写成 `worrd://…` 再交给主 App
- 主 App 不修改、不重签名；删除前缀就是删除对应转发 App 并注销

规则：2–32 位小写字母/数字/`-`/`.`，字母开头；`http`、`file`、`mailto` 等保留前缀会被拒绝。`worrd://` 始终保留。

实测：`newworrd://theme` → 主 App 收到 `worrd://theme`，查询次数正常递增。

## 单词本

每次查词自动入库（`lookup_count + 1`），数据库：

```
~/Library/Application Support/Worrd/wordbook.sqlite
```

表：`words`（词条、音标、释义、查询次数、首末时间）、`lookups`（每次查询的原始输入与入口）。

查看：

```bash
sqlite3 ~/Library/Application\ Support/Worrd/wordbook.sqlite \
  "select headword, lookup_count, datetime(last_looked_at,'unixepoch','localtime') from words;"
```

菜单栏图标 → **单词本…** 打开窗口：

- 左侧列表（词头 / 音标 / 首条释义 / 查询次数 / 最近时间），可搜索、右键删除
- 右侧详情：完整释义、查询次数、可编辑笔记（每次按键即时落库）
- AI 生成的词条带 `AI` 标签
- 窗口尺寸 940×620

## 调试

```bash
# 把浮窗渲染成 PNG，方便无头检查（delay 控制等待 AI 的时间）
open "worrd://view/snapshot?q=theme&delay=6"
# 把单词本窗口渲染成 PNG
open "worrd://view/wbshot"
# 把设置窗口渲染成 PNG
open "worrd://view/settingsshot"
# 命令行增删自定义前缀（设置界面是同一套逻辑）
open "worrd://view/scheme?add=newworrd"
open "worrd://view/scheme?remove=newworrd"
```

## 三种入口怎么试

### 1. URL scheme

```bash
open "worrd://theme"
open "worrd://lookup?q=serendipity"
open "worrd://主题"
```

也可以在浏览器地址栏、Raycast / Alfred 的 quicklink 里用。

### 2. 系统服务

在任意 App 里选中一个单词 → 右键 → **服务** → **用 Worrd 查词**。

想给它配快捷键：系统设置 → 键盘 → 键盘快捷键 → 服务 → 文本 → 找到「用 Worrd 查词」→ 双击右侧添加，比如 `⌃⌥W`。

### 3. App Intent（重点，决定要不要做快捷指令）

先确认 App 已经运行过一次（菜单栏有图标），然后：

- `⌘Space` → 输入 `worrd` 或 `查词` → 看有没有一条 **用 Worrd 查词** 的动作；
- 选中它之后，Spotlight 里应该出现「单词」输入框，输入 `theme` 回车；
- 如果 Spotlight 不显示，打开**快捷指令** App，在动作库里搜 `Worrd`，看这个动作是否存在 —— 存在说明系统读到了，只是 Spotlight 没索引到。

Spotlight 的 App Intent 索引可能延迟几十秒；刚装完可以先等一会儿，或者退出登录再试。

## 已知情况

- 词典是系统自带的《牛津英汉汉英词典》，通过私有 API `DCSDictionaryCreate` 绑定，双向查询都通。
- 服务与 URL 都会调用 `NSApp.activate`，浮窗会抢焦点。如果测下来觉得打断，可以改成不激活的 HUD 面板。
- 浮窗目前固定 540×430，内容超出时滚动；样式只是能看，不是最终视觉。
- 应用是 ad-hoc 签名，仅供本机使用。

## 文件

- `Worrd/DictionaryService.swift` — 词典定位、查询、轻量排版
- `Worrd/LookupPanel.swift` — 浮窗 + SwiftUI 内容
- `Worrd/AppDelegate.swift` — URL scheme、Services、菜单栏入口
- `Worrd/LookupIntent.swift` — App Intent + App Shortcuts 短语
- `Worrd/Info.plist` — `CFBundleURLTypes`、`NSServices`、`LSUIElement`
