# 主界面、控制面板、设置与历史：电脑 agent 逐控件审查

日期：2026-10-25。范围：源码只读盘点与待执行测试设计；本文件不代表下列 UI 用例已经通过。此轮未修改应用代码。源码路径相对项目根目录 `.`，行号以审查时源码为准。

## 执行方式与覆盖口径

阅读项目可以多 agent 并行；同一 macOS 桌面只能由一个 agent 操作，其他 agent 审核截图、日志与覆盖账本。各独立入口分别计覆盖，不能因为它们共用 action 就只点击其中一个。重复数据项按首、中、尾及最后一条覆盖，合成样本小集合中的每个可见按钮均实际点击。

每条用例记录：case ID、构建身份、测试数据根目录、前置状态、定位依据、实际动作、明确等待条件、动作前后截图、结果、恢复动作。结果只用“通过、失败、未验证、不适用”；不适用附原因。截图和控件树只能证明可见状态，不能单独证明文件保存、系统授权、后台进程或全局事件成功。

操作使用 UI 已观察到的控件标识/文字/角色定位；自定义绘制控件找不到时重新观察屏幕，使用本次截图验证的位置，不用猜测的历史坐标。控件不可见时先滚动或建立条件状态；出现新菜单后枚举全部菜单项并逐一补入账本。等待目标页、菜单、确认框、外部文件窗口或数量变化出现，超过约定超时记录失败证据，不用连续盲点修复。

下面表格中的参数列表均需展开为独立执行记录，例如 `NAV-01[home]`、`PREF-02[de]`；每个参数都要求动作和断言，不能整组只留一张截图。

## 1. 主窗口与首页

| ID | 控件/参数 | 前置条件与动作 | 等待与断言 | 源码证据 |
|---|---|---|---|---|
| NAV-01 | 首页、翻译记录、截图记录、快捷键设置、偏好设置，5个导航按钮 | 任意页点击每个目标；重复点击当前页；从另外4页分别返回 | 内容、选中样式与目标一致；无重复窗口、空白页或旧确认框 | `Sources/SnapLex/UI/DashboardView.swift:5–20,84–103,116–132` |
| NAV-02 | 导航与长页状态 | 历史页/偏好页滚动到底→切页→返回；有确认框时取消后切页 | 导航始终可用；滚动内容不覆盖固定顶部；弹框不留到其他页 | `DashboardView.swift:67–137` |
| HOME-01 | 立即截图 | 首页前台点击→建立选区→Esc取消；再从状态栏重开控制台 | 主页面在捕捉前隐藏；截图不冻结主页；取消后操作可恢复 | `DashboardView.swift:196–198`；`WindowManager.swift:372–390` |
| HOME-02 | 快捷操作“截图” | 与HOME-01单独点击并完成一次保存链路 | 正确覆盖层出现；合成图片保存后记录增加一次 | `DashboardView.swift:226–228` |
| HOME-03 | 快捷操作“录屏” | 点击，观察助手；再取消/关闭 | 正确录屏助手可见且可退出；不误触截图 | `DashboardView.swift:229–231` |
| HOME-04 | 快捷操作“贴图” | 合成图片、合成文字、空剪贴板分别点击 | 有效内容产生正确贴图；无内容分支不崩溃且可继续操作 | `DashboardView.swift:232–234`；`WindowManager.swift:393–398` |
| HOME-05 | 最近截图“查看全部” | 空与非空两种状态点击 | 截图记录页可见，数量与首页一致 | `DashboardView.swift:267–269` |
| HOME-06 | 今日高频词“查看记录” | 空与非空状态点击 | 翻译记录页可见，统计与样本一致 | `DashboardView.swift:297–299` |
| HOME-07 | 最近翻译“查看全部” | 空与非空状态点击 | 翻译记录页可见，不能误转截图页 | `DashboardView.swift:333–335` |
| HOME-08 | 最多4张首页截图预览 | 注入横图、竖图、超宽图、透明图；每张分别点击；补损坏/外部已删文件 | 系统图片应用打开对应文件；返回后首页可操作；缩略图不越界；失败分支不挂死 | `DashboardView.swift:274–288` |
| HOME-09 | 首页统计和只读卡片 | 已知时间样本：今日、昨天、7天前、未来；含重复词 | 今日/近7天翻译数、截图总数、前5高频词、今日前5条翻译符合实际口径；非按钮不虚构点击 | `DashboardView.swift:160–182,201–218,305–361` |
| WIN-01 | 红色关闭 | 主窗口5页分别关闭，状态栏重开 | 主窗口消失但应用仍活着；状态栏和热键服务仍可用；只出现一个主窗口 | `WindowManager.swift:417–457`；`SnapLexApp.swift:48–63` |
| WIN-02 | 最小化、缩放、拖动、尺寸 | 点击系统窗口按钮；拖动；缩至最小；最大化后恢复 | 不丢内容/按钮；导航可见；最小尺寸1080×720、初始1180×820 | `WindowManager.swift:420–434`；`DashboardView.swift:136` |
| WIN-03 | ⌘Q隐藏与重开 | 主窗口前台按当前“隐藏主页面”绑定；状态栏和Dock分别重开 | 窗口隐藏而非进程退出；重开有可用首页；另测其他页恢复行为 | `SnapLexApp.swift:48–63,131–147`；`Models/Models.swift:127,163` |
| WIN-04 | 普通页面Esc | 各页无菜单/弹窗/录制时Esc；再重开 | 记录实际窗口隐藏和焦点结果；不能把菜单取消与整个窗口隐藏混为一项 | `Core/EscapeKeyManager.swift:50–61,65–103` |

## 2. 状态栏控制面板

| ID | 控件 | 前置条件与动作 | 等待与断言 | 源码证据 |
|---|---|---|---|---|
| PANEL-01 | 状态栏图标 | 点击打开→再次点击关闭→打开→点击外部关闭；主窗口关闭后再打开 | 360×600面板正常出现/消失；无重复面板；主窗口关闭不移除图标 | `SnapLexApp.swift:65–125`；`ControlPanelPopoverView.swift:251` |
| PANEL-02 | 顶部“打开控制台”图标 | 不同原页面下点击 | popover关闭；控制台首页出现 | `ControlPanelPopoverView.swift:79–88`；`SnapLexApp.swift:111–114` |
| PANEL-03 | 截图 | 面板打开时点击，取消；再次完成截图 | 面板先关闭，覆盖层正常；不把面板冻入图像；历史增加一次 | `ControlPanelPopoverView.swift:103–105`；`SnapLexApp.swift:99–102` |
| PANEL-04 | 录屏 | 点击并进入助手，再退出 | 面板关闭、录屏助手出现；取消能回到正常桌面 | `ControlPanelPopoverView.swift:106–108`；`SnapLexApp.swift:103–106` |
| PANEL-05 | 贴图 | 图片/文字/空剪贴板分别点击 | 面板关闭，正确分支可观察；贴图可关闭 | `ControlPanelPopoverView.swift:109–111`；`SnapLexApp.swift:107–110` |
| PANEL-06 | 最近截图“查看全部” | 空/非空分别点击 | 截图页出现，popover关闭 | `ControlPanelPopoverView.swift:127–129` |
| PANEL-07 | 前3张截图行 | 1/3/4张样本；可见的每行点击 | 正确文件打开；最多显示3条，不混淆首页最多4张 | `ControlPanelPopoverView.swift:142–146` |
| PANEL-08 | “查看翻译记录” | 点击 | 翻译页出现、popover关闭 | `ControlPanelPopoverView.swift:202–213` |
| PANEL-09 | 底部“打开控制台” | 单独点击，不由顶部按钮代测 | 首页出现，面板关闭 | `ControlPanelPopoverView.swift:236–246` |
| PANEL-10 | 电源“退出SnapLex” | 批次最后点击，记录PID后再启动 | 应用进程结束、图标消失；重新启动可恢复。与⌘Q隐藏独立 | `ControlPanelPopoverView.swift:224–232`；`SnapLexApp.swift:287–290` |
| PANEL-11 | 内容滚动 | 空/1/3/大量记录滚至底再回顶 | 截图/录屏/贴图三个主操作固定可见；底部退出和控制台可见；无裁切 | `ControlPanelPopoverView.swift:95–119,219–251` |
| PANEL-12 | 24小时统计 | 合成昨日同一时刻前后与今日零点样本 | 最近24小时计数与首页“今日”允许不同；图表为最近7日，前三词正确 | `ControlPanelPopoverView.swift:26–44,154–199` |

## 3. 翻译记录与忽略词

| ID | 控件/参数 | 前置条件与动作 | 等待与断言 | 源码证据 |
|---|---|---|---|---|
| HIST-01 | 今日、近7天、近一月、近30天，4个时间选项 | 每选项分别点击，在两个记录视图各执行一次 | 数量、图表、列表同步；空范围正确 | `TranslationHistoryView.swift:76–81,83–107` |
| HIST-02 | 词频统计、翻译记录，2个视图选项 | 每种日期范围切换两模式 | 对应列表可见；默认是词频统计，不误以为记录列表 | `TranslationHistoryView.swift:21–22,112–124` |
| HIST-03 | 忽略词入口 | 两个模式各点击；sheet打开时滚动 | 忽略词sheet可见；原页不被误清空 | `TranslationHistoryView.swift:61–66,132–134` |
| HIST-04 | 清空翻译记录垃圾桶 | 空时尝试；非空点击→取消；再点→确认 | 空时禁用；取消保留；确认清空记录与统计；忽略词仍保留 | `TranslationHistoryView.swift:67–73,135–143`；`Storage/TranslationHistoryStore.swift:248–254` |
| HIST-05 | 记录每行“×” | 首/中/尾/最后一条，过滤后分别删除 | 只删目标；图表、指标、词频、首页同步；最后条删除后为空态 | `TranslationHistoryView.swift:185–192` |
| HIST-06 | 词频行“加入忽略词” | 词在多条记录中出现；选择首/中/尾词 | 词立即从词频消失；原记录保留；高频词摘要刷新 | `TranslationHistoryView.swift:233–240` |
| HIST-07 | 记录原文、上下文文字选取 | 分别拖选、复制到专用合成验证区 | 文字可选，复制准确；不会自触发划词浮窗 | `TranslationHistoryView.swift:162–176` |
| HIST-08 | 两类列表滚动 | 数百条记录、101+词 | 列表可滚动；词频只展示前100项是当前实现，不能要求第101词可见 | `TranslationHistoryView.swift:147–199,202–249` |
| IGN-01 | 输入框 | 输入→清空；全空白；前后空白；大小写重复；重音变体 | 空白“+”禁用；标准化去重；不产生空词 | `TranslationHistoryView.swift:295–301`；`TranslationHistoryStore.swift:205–219,352–354` |
| IGN-02 | “+”添加 | 有效单词后点击 | 列表出现一次；输入框清空；列表不区分大小写排序 | `TranslationHistoryView.swift:298–301,324–326`；`TranslationHistoryStore.swift:217–219` |
| IGN-03 | Return添加 | 有效单词后按Return，与“+”独立覆盖 | 结果同IGN-02，无重复添加 | `TranslationHistoryView.swift:297` |
| IGN-04 | 每行“−”移除 | 首/中/尾/最后一词分别移除 | 对应词恢复统计；其他忽略词不变；重开/重启持久化 | `TranslationHistoryView.swift:305–315`；`TranslationHistoryStore.swift:222–235` |
| IGN-05 | 完成 | 修改后点击完成，再重开 | sheet关闭；改动保留；父页可用 | `TranslationHistoryView.swift:291` |
| IGN-06 | sheet内Esc | 输入框焦点、无焦点两种状态Esc | 观察sheet是否正确关闭，主窗口是否意外隐藏；属于Esc专项 | `EscapeKeyManager.swift:52–61,91–92` |

统计断言必须符合实现：单条翻译中同词出现多次只计一次；跨记录才累加。同次数按最新日期降序。中文源文使用译文作学习词，源文作上下文；非中文反过来。证据：`TranslationHistoryStore.swift:268–301,312–324`。

日期样本分别放在边界前后1秒，并含未来记录。“近一月”从当前时刻倒推一个月；“近30天”从29天前零点开始；“近7天”从6天前零点开始。`Core/TranslationHistoryPeriod.swift:20–35`。不以两个按钮显示相同数据为唯一结论，必须准备能区分口径的样本。

## 4. 截图记录

| ID | 控件 | 前置条件与动作 | 等待与断言 | 源码证据 |
|---|---|---|---|---|
| SHOT-01 | 刷新图标 | 空状态；测试目录增加/外部删除合成文件后点击 | 实际文件与列表/数量同步；不读取生产目录 | `ScreenshotHistoryView.swift:28–33` |
| SHOT-02 | 清空垃圾桶 | 空时；非空点击→取消；再次→确认 | 空时禁用；取消不改文件；确认清空列表与测试图片 | `ScreenshotHistoryView.swift:34–40,65–71` |
| SHOT-03 | 缩略图单击 | 横/竖/超宽/透明样本每张点；首/末张 | 外部应用打开准确文件；返回后列表正常 | `ScreenshotHistoryView.swift:99` |
| SHOT-04 | 右键菜单“打开图片” | 每种代表图片右键后点击菜单项 | 正确文件打开；不能用单击代测 | `ScreenshotHistoryView.swift:100–101` |
| SHOT-05 | 右键菜单“在Finder中显示” | 右键点击 | Finder显示并选中目标测试文件 | `ScreenshotHistoryView.swift:102–104` |
| SHOT-06 | 右键菜单“删除截图” | 首/中/尾测试文件分别执行 | 目标图片与列表项删除，其他文件不变 | `ScreenshotHistoryView.swift:106` |
| SHOT-07 | 卡片右下垃圾桶 | 与右键删除独立覆盖；最后一张 | 文件/列表/总数变化一致；最后一张后空态 | `ScreenshotHistoryView.swift:118–125` |
| SHOT-08 | 网格滚动与缩放窗口 | 0/1/3/100/101/1000张；最小与最大窗口 | 缩略图对应正确、没有越界遮挡、按钮可见；统计正确 | `ScreenshotHistoryView.swift:10,51–62,83–97` |
| SHOT-09 | 损坏PNG/已删图 | 仅在隔离目录制造损坏和已删状态；刷新、打开、删除 | 不能崩溃、无限占位而无恢复；实际结果如实记录 | `ScreenshotHistoryStore.swift:94–108`；`ScreenshotHistoryView.swift:89–93,137–139` |
| SHOT-10 | 文件操作失败 | 隔离目录模拟不可删文件，再删除/清空/降保留数 | UI不能把未删文件误报成功；刷新后状态一致。当前代码忽略部分文件错误，需实测 | `ScreenshotHistoryStore.swift:115–137` |

## 5. 偏好设置

| ID | 控件/参数 | 前置条件与动作 | 等待与断言 | 源码证据 |
|---|---|---|---|---|
| PREF-01 | 跟随系统、浅色、深色3段 | 各点一次；系统浅/深分别进行；已打开浮窗同时观察；关闭重开/重启 | 窗口背景、文字、popover外观一致且可读；选值持久化 | `SettingsView.swift:80–90`；`WindowManager.swift:444–451` |
| PREF-02 | English、简中、繁中、日、韩、法、德7菜单项 | 每项选择后遍历5页、popover与弹框；每次重新定位 | 当前语言正确，关键文案无溢出/缺失；选择持久化 | `SettingsView.swift:97–109` |
| PREF-03 | Google、Apple两引擎菜单项 | 各选择；已打开卡片时再切；重开/重启 | 引擎值与实际请求一致；失败可恢复；无重复请求 | `SettingsView.swift:115–122` |
| PREF-04 | 鼠标划词开关 | 开→实际只读选区→关→同样选区→再开 | 关时不出条，开时可恢复；不影响编辑区保护 | `SettingsView.swift:142–146` |
| PREF-05 | 双击⌘C开关 | 开/关；与鼠标开关四组合 | 分别控制对应触发；不串扰 | `SettingsView.swift:150–154` |
| PREF-06 | 条件“去授权” | 未授权才显示；点击后分别允许/拒绝 | 系统提示可操作、不会被应用覆盖；状态可刷新；不循环弹 | `SettingsView.swift:190–193` |
| PREF-07 | AX刷新图标 | 未授权、已授权、撤销后分别点；重开页 | 状态文字/标记与实际权限一致 | `SettingsView.swift:196–198,393–396` |
| PREF-08 | 登录时启动开关 | 开/关；系统登录项核验；重开页面 | 系统服务状态与UI一致；失败有错误文案；恢复测试前状态 | `SettingsView.swift:206–219,396` |
| PREF-09 | 自动记录划词翻译开关 | 开/关各完成一次真正划词翻译 | 仅开启时增加selection记录，不能用手动输入翻译代替 | `SettingsView.swift:278–282`；`TranslationHistoryStore.swift:103–112` |
| PREF-10 | 自动记录截图翻译开关 | 开/关各完成一次OCR翻译 | 仅开启时增加screenshot记录，与另一记录开关独立 | `SettingsView.swift:284–288`；`TranslationHistoryStore.swift:108–112` |
| PREF-11 | 保留数量“+” | 点击并观察；上界1000状态再点 | 步长10，上界不越过1000；数值持久化；已有图片不误删 | `SettingsView.swift:641–659`；`Models/Models.swift:218–223` |
| PREF-12 | 保留数量“−” | 点击；下界1再点；超过新限额样本 | 下界不低于1；超额时仅淘汰最旧图片；文件和列表一致 | 同上；`ScreenshotHistoryStore.swift:127–137` |
| PREF-13 | 查看翻译记录 | 点击 | 路由到翻译记录，无第二独立窗口 | `SettingsView.swift:293–297`；`WindowManager.swift:400–402` |
| PREF-14 | 管理截图记录 | 点击 | 路由到截图记录，无第二独立窗口 | `SettingsView.swift:298–302`；`WindowManager.swift:404–406` |
| PREF-15 | 检查更新 | 点击；checking时再尝试；成功/失败后再点 | 检查中禁用；最新/无正式发布/新版本/失败各自文案正确；失败能重试 | `SettingsView.swift:333–342,400–428` |
| PREF-16 | 条件“查看GitHub发布页面”链接 | 构造有更新状态后点击 | 打开正确releaseURL；不把更新检查误写成自动安装 | `SettingsView.swift:345–359` |
| PREF-17 | 更新说明文本选择 | 有非空notes，选择复制；超长notes | 最多6行布局不挤掉链接，文本可选 | `SettingsView.swift:349–354` |

PREF-15的多种响应需受控网络桩或独立环境才能确定覆盖；当前服务不是通过该View公开注入，不能声称仅靠真实“检查更新”一次点击覆盖全部状态。联网检查与打开发布链接单独记录是否实际执行。

自定义开关实现是没有显式可区分AX标签的`Button`，不是原生`Toggle`，因此不能只搜索AX checkbox就宣称没有此控件。必须结合行标题和本次屏幕位置定位。证据：`SettingsView.swift:533–583`。

## 6. 快捷键12行与恢复默认

默认绑定证据：`Models/Models.swift:100–168`。以下12行都必须各自产生执行记录。

| 参数ID | 行标题 | 默认绑定 | 触发后的最小结果断言 |
|---|---|---|---|
| K01 | 划词直接翻译 | ⌃⌘A | 专用只读合成选区进入翻译卡片，编辑区域保护仍有效 |
| K02 | 区域截图主键 | F1 | 覆盖层出现且Esc可取消 |
| K03 | 区域截图备用 | ⌃⌘S | 与K02独立实际触发 |
| K04 | 打开/隐藏翻译卡片 | ⌃⌘D | 连续两次打开/隐藏符合实现 |
| K05 | 屏幕贴图主键 | F3 | 合成图片/文字正确贴图 |
| K06 | 屏幕贴图备用 | ⌃⌘P | 与K05独立实际触发 |
| K07 | 恢复上个关闭贴图 | ⇧F3 | 先关闭合成贴图，再按键恢复同一内容 |
| K08 | 解锁所有贴图 | ⌃⌘X | 先制造鼠标穿透贴图，再按键；恢复可交互 |
| K09 | 屏幕录制 | ⌃⌘R | 助手出现，可取消 |
| K10 | 停止录屏 | F10 | 合成录制期间触发，录制停止并进入正确后续状态 |
| K11 | 打开偏好设置 | ⌘, | SnapLex前台时打开偏好页；这是本地绑定 |
| K12 | 隐藏主页面 | ⌘Q | 主窗口隐藏、进程仍活着；这是本地绑定，不能当真正退出 |

| ID | 参数/操作 | 动作步骤 | 等待与断言 | 源码证据 |
|---|---|---|---|---|
| KEY-01[K01…K12] | 每行录制按钮再次点击取消 | 点击行按钮→观察“按下新快捷键…”→再次点击 | 退出录制，旧值不变 | `SettingsView.swift:608–634` |
| KEY-02[K01…K12] | 每行Esc取消 | 点击行→按Esc | 录制终止，绑定不变；另观察是否误隐藏主窗口 | `ShortcutRecorderController.swift:35–40`；`EscapeKeyManager.swift:52–61` |
| KEY-03[K01…K12] | 保存有效新绑定 | 点行→输入经观察可用的新组合→实际触发该功能→重启→再触发 | 新值显示并持久化；旧值失效；新功能准确 | `ShortcutRecorderController.swift:53–72`；`Models/Models.swift:281–285` |
| KEY-04 | 无修饰字母 | 代表行录制输入裸字母，再输入有效键 | 显示需修饰键错误，仍能继续并成功保存 | `ShortcutRecorderController.swift:47–50` |
| KEY-05 | 冲突 | 给代表行输入另一行已有绑定，再改有效键 | 显示占用行；两绑定原值不被改坏；可恢复 | `ShortcutRecorderController.swift:62–66` |
| KEY-06 | 全局编辑保留键 | 给全局行输入⌘C等保留编辑组合 | 拒绝并显示原因；不能劫持正常复制 | `ShortcutRecorderController.swift:58–60` |
| KEY-07 | 功能/方向键 | 代表行输入允许的裸功能/导航键 | 按实现接受，执行功能正确；不造成无法取消 | `ShortcutRecorderController.swift:47–50,82–85` |
| KEY-08 | 录制期间切行 | 行A开始→点行B→输入 | 只更新B；A不误改；没有两个monitor吞键 | `ShortcutRecorderController.swift:17–26` |
| KEY-09 | 录制期间切页/关窗 | 开始录制→切偏好页/关窗→再打开→输入或Esc | 录制状态不应形成隐形吞键；记录实际结果，此处无显式页面消失取消 | `SettingsView.swift:608–634`；`ShortcutRecorderController.swift:17–32` |
| KEY-10 | 恢复默认 | 改多行→点击恢复；录制过程中再点击恢复 | 12行全恢复、capture取消、错误清除；10全局热键实际恢复 | `SettingsView.swift:239–242`；`Models/Models.swift:287–291` |

## 7. Esc菜单观察：待确认现象，不能直接定为缺陷

主agent本轮提供的电脑操作观察：打开偏好设置→应用语言下拉（观察到7个选项）→`pressKey Escape`，下一次AX读取不在偏好页而回到首页，窗口索引重新构建。存在全局Esc隐藏窗口后，自动化重新激活/读取导致重开的可能；仅此观察不足以确认产品bug。

源码风险解释：`EscapeKeyManager.start`为所有本地keyDown安装monitor；遇Esc仅在`NSApp.modalWindow != nil`时放行，其他情况异步调用dismiss并返回nil（`Core/EscapeKeyManager.swift:50–61`）。dismiss优先处理截图/倒计时/贴图，随后若有可见keyWindow则`orderOut`（`:69–92`）。代码没有显式检查“原生菜单正在跟踪”“SwiftUI sheet/confirmation是否活动”“快捷键正在录制”。若菜单或sheet不被macOS报告为modalWindow，Esc可能先隐藏整个窗口。另有快捷键录制monitor也处理Esc（`ShortcutRecorderController.swift:21–25,35–40`），两个monitor执行顺序与事件消费需实测。

高优先待执行用例：

1. 偏好页开应用语言菜单→Esc；在任何重新激活前，立刻检查截图、可见窗口与进程；预期菜单取消、语言不变、偏好页仍可操作。再单独执行重开，区分隐藏与导航重置。
2. 翻译引擎菜单、截图右键菜单逐一重复，确认不是语言菜单特例。
3. 清空确认框Esc、忽略词sheet有/无文本焦点Esc分别执行；确认首先取消当前弹层且不删除数据。
4. 快捷键录制Esc确认只取消录制，随后普通页面Esc独立测试全窗口隐藏语义。
5. 原生保存面板Esc，确认因modalWindow豁免而只取消保存；记录应用其他窗口是否保留。
6. 每例保留按Esc之前与之后的截图、AX快照时间、可见窗口身份及是否执行了app激活；避免观察工具本身改变现场。

## 8. 源码存在但正常路径不可达的入口

- `SettingsPinButton`只在`SettingsView(section:.all)`显示（`SettingsView.swift:27–61`）；当前五页Dashboard传的是`.preferences/.shortcuts`（`DashboardView.swift:129–131`），`showSettingsWindow`也转到Dashboard偏好页（`WindowManager.swift:413–415`）。因此独立设置窗置顶按钮列“源码存在、正常入口未暴露”，不虚构点击用例。
- 当前状态栏是popover，`SnapLexApp.swift:80`明确`item.menu = nil`。文件中旧`@objc`的全部贴图隐藏/关闭/历史等方法存在，不代表UI里存在对应菜单；应在实际可见控件树确认后才计入口。
- 翻译历史没有独立刷新按钮，截图历史有；不能沿用“所有历史页都有刷新”的假设。
- `GlobalShortcut.quitApp`变量名不等于退出功能，标题和行为均是隐藏主页面；真正退出为popover电源按钮。

## 9. 隔离、风险与现有计划遗漏

`SNAPLEX_ISOLATED_TEST_DATA_ROOT`只重定向翻译SQLite与截图目录（`Storage/LocalTestDataPaths.swift:6–27`；`TranslationHistoryStore.swift:49–58`；`ScreenshotHistoryStore.swift:28–38`）。`AppSettings`仍用`UserDefaults.standard`（`Models/Models.swift:186–223`），登录项是系统服务，全局热键也影响同一桌面。测试副本须有独立bundle身份，并验证偏好域实际隔离；只设置该环境变量不足以宣称所有设置隔离。保留真实用户设置、剪贴板和登录项的恢复记录，只删除本次合成数据。

现有 `docs/testing/desktop-test-plan.md` 与 `snaplex-regression-plan-zh.md` 已说明逻辑/服务/UI/系统层分工、合成数据、主要链路、六种外观组合、语言、20轮与30分钟测试；但本范围缺少可验收的逐控件账本、12行快捷键逐项实触发、Stepper两箭头边界、忽略词Return与加号双入口、截图单击/右键菜单独立入口、条件更新链接、统计口径细节、菜单Esc与录制中切页。

执行时应补上“点击后结果”证据，而非只统计按钮点击：页面身份、目标文件、数量变化、焦点、窗口数量、后台进程、旧结果不会重开。状态栏最近24小时与首页今日不同，词频每条记录去重、前100词展示上限等都是避免误判的必要oracle。

历史文档中的页面路由通过不继承为本轮截图、跨应用划词、TCC、录屏或全按钮通过。本审查仅提供源码清单；上文未附本轮具体操作证据的用例全部维持“未验证”。
