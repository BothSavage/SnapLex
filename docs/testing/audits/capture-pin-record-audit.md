# 截图、贴图、长截图与录屏逐控件测试审查

日期：2026-10-25。范围：当前仓库源码的只读审查，**未操作桌面，未执行下列场景，所有场景初始状态均为未验证**。本文为统一执行计划的控件依据，不代表功能已通过。

源码根目录：`.`。表中源码路径相对于该目录；行号对应审查时版本，后续改动后需重新确认。

## 执行方法

- 每个按钮、菜单项和快捷键入口分别记录实际操作；同名功能经另一入口通过，不能代替该入口的点击覆盖。
- 操作前确认前置状态，操作后等待可见结果，核对输出内容；按钮变色、回调发生、文件存在不单独构成功能通过。
- 建议等待上限：普通窗口/工具栏 5 秒，OCR/翻译/图像处理 30 秒，录屏导出 60 秒。超时截图、记录当前状态并尝试该功能正常取消路径，不盲目连续点击。
- 每条记录包含：case ID、构建标识、前置 fixture、控件入口、动作、预期、实际、证据、清理结果。结果限通过/失败/未验证/不适用，后两者必须说明原因。
- 同一实体桌面只允许一个操作 agent；源码阅读和结果审查可并行。
- 使用合成图像、合成长页面、测试音频和独立数据目录。保存、覆盖、清理仅限本轮专用目录；不要撤销日常权限或操作真实历史制造故障。

## 控件库存

| 区域 | 逐一操作的控件 | 源码证据 |
|---|---|---|
| 截图主栏（23 个） | 矩形、椭圆、直线、箭头、画笔、荧光笔、马赛克、模糊、序号、文字；撤销、重做、长截图、录屏、翻译、提取文字、背景虚化、提取主体、二维码/条码、贴图、保存、取消、完成复制 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:2191`；`Sources/SnapLex/Snipaste/SnipasteModels.swift:4` |
| 截图样式子栏 | 线宽 2/4/8；矩形/椭圆空心/实心；文字加粗、斜体、字号减/加；红橙黄绿蓝紫白 7 色 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:2456` |
| 录屏子栏（12 个） | 区域/窗口/全屏；0/3/5 秒；指针、点击波纹、按键显示、系统声音、麦克风；开始。窗口模式另有最多 10 个窗口选择项 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:2310`、`:2407` |
| 活动录屏栏 | 暂停/继续、结束；倒计时态只有结束 | `Sources/SnapLex/Snipaste/ScreenRecorderAssistant.swift:629` |
| 录屏保存面板 | MP4/GIF、文件名、目录、新建目录、保存、取消、同名覆盖确认 | `Sources/SnapLex/Snipaste/ScreenRecorderAssistant.swift:336`、`:575` |
| 贴图主栏（14 个） | 缩小、放大、1:1、旋转、背景虚化、提取主体、标注、翻译、OCR、阴影、穿透、复制、保存、关闭 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:1436` |
| 贴图标注子栏 | 同 10 个标注工具、撤销；文字加粗/斜体/字号减加；7 色。没有可见重做、线宽和填充按钮，不在台账虚构 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:1515` |
| OCR 抽屉 | 看原文/看译文（有翻译缓存才出现）、复制全部、可编辑文本区 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:2111` |
| 贴图右键菜单 | 原位翻译/还原、OCR 抽屉开关、标注开关、复制、保存、旋转、水平镜像、阴影、折叠/展开、穿透、关闭 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:1816` |
| 穿透伴随窗 | 独立“退出穿透”按钮 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:1059`、`:1099` |
| 长截图面板 | 自动滚动/停止滚动、取消、完成；实时预览滚动区域 | `Sources/SnapLex/Snipaste/ScrollingCaptureEngine.swift:879` |

## CAP：截图基本动作与逃生

| ID | 前置与操作 | 可观测预期 | 源码 |
|---|---|---|---|
| CAP-01 | 从首页、状态栏、热键分别进入截图；不框选按 Esc | 每个入口可见覆盖层；Esc 后覆盖层/工具栏/放大镜消失，能立即重进 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:117`、`:1685` |
| CAP-02 | 框选后点击取消；连续进入/退出 10 轮 | 每轮可取消，无孤立辅助窗、无输入锁死 | 同上 |
| CAP-03 | 在合成测试窗口悬停→点击；四方向拖出选区；8 个调整柄逐一调整 | 框、尺寸标签、窗口识别和最终裁切对应一致 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:1441` |
| CAP-04 | 移动选区至屏幕四边和 Dock 上方；展开录屏/样式子栏 | 所有操作行在屏内，无工具栏覆盖尺寸标签或无法点击 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:601` |
| CAP-05 | 方向键各移动 1px；Shift+方向键各移动 10px | 位置标签及裁切平移符合步长 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:1718` |
| CAP-06 | 已知纯色色块上移动光标，按 C；Shift 触发取色格式切换行为需现场确认 | 放大镜及颜色值对应样本；剪贴板精确匹配；完成选区后移向工具栏放大镜不残留 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:881`、`:1685`、`:1734` |
| CAP-07 | 同样本分别点完成复制、Enter、小键盘 Enter、双击空白选区 | 覆盖层退出，剪贴板图像裁切/标注一致，历史条数符合一次完成 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:1479`、`:2120` |
| CAP-08 | 点保存/⌘S，各执行保存和取消；保存至专用目录 | 保存 PNG 可打开且内容正确；取消无目标文件；记录取消时历史行为 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:2093` |
| CAP-09 | 点贴图/F3/⌘T 分别完成 | 三入口均生成对应贴图、关闭覆盖层；图像与裁切一致 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:1999`、`:1698` |
| CAP-10 | 创建 7、8、31、32px 宽/高选区后分别复制或录屏 | 8px 截图渲染门槛、32px 录屏门槛对应行为清楚；失败有退出路径，无锁死 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:1913`；`Sources/SnapLex/Snipaste/ScreenCaptureRecordingPipeline.swift:69` |

注意：`renderCroppedAnnotatedImage()` 在打开保存面板前已经写截图历史；取消保存不能先假设历史不增加（`SnipasteCaptureOverlay.swift:1961`）。

## ANN：标注逐工具生命周期

下列每一工具均须在**截图画布与贴图画布分别执行**。两者实现不同，不可合并通过结果。

统一动作：点工具→创建→点空白取消选择→再次命中→再拖动→缩放→旋转→撤销→重做（贴图用快捷键）→复制/保存→检查输出图片。

| ID | 工具/控件 | 专属步骤与预期 |
|---|---|---|
| ANN-01 | 矩形 | 三线宽各画一条；空心/实心分别输出；边框粗细/填充/位置正确 |
| ANN-02 | 椭圆 | 同矩形，增加极扁椭圆；缩放/旋转后无错误裁切 |
| ANN-03 | 直线 | 四方向和短线；端点跟随拖动，线宽/色正确 |
| ANN-04 | 箭头 | 四方向和短箭头；箭头方向与拖动终点一致 |
| ANN-05 | 画笔 | 曲线、快速转折、两笔连续画；不误移动前一笔 |
| ANN-06 | 荧光笔 | 覆盖已知黑字和彩色区域；输出保留半透明叠加，可见下层内容 |
| ANN-07 | 马赛克 | 覆盖固定文字/棋盘格；输出应验证真实像素化效果，不能只看灰框 |
| ANN-08 | 模糊 | 覆盖固定文字/棋盘格；输出应验证真实模糊，区别于马赛克 |
| ANN-09 | 序号 | 连点 1/2/3→撤销→重做→再建；核对实际序号与既定产品预期 |
| ANN-10 | 文字 | 空白提交、英/中/emoji、长串；输入中改颜色/粗斜体/字号；Enter、切工具提交；Esc 焦点行为单独记证据 |
| ANN-11 | 颜色 | 7 色逐一选取并输出；高亮与实际笔色对应 |
| ANN-12 | 字号 | 减到 10、加到 120，确认边界禁用；切换大小不丢输入、不跳位 |
| ANN-13 | 撤销/重做 | 撤销到空/重做到空；检查禁用态；撤销后新建清空 redo；已有文字编辑时动作先提交 |
| ANN-14 | 命中与变换 | 第一次点击选中，第二次拖动移动；8 方向柄/旋转柄正确；叠层选择最上方；连续绘制不误拖调整框 |

证据：`Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:1449`、`:1492`、`:1802`、`:1900`、`:2456`；`Sources/SnapLex/Snipaste/SnipastePinManager.swift:1856`、`:1925`；字号边界 `Sources/SnapLex/Snipaste/SnipasteModels.swift:41`。

## VIS：图像效果、扫码、OCR 与原位翻译

| ID | 控件与操作 | 可观测预期 | 源码 |
|---|---|---|---|
| VIS-01 | 已知主体图分别点背景虚化、提取主体；截图与贴图两入口 | 完成图实际虚化背景/保留透明背景，主体不消失；能保存并检查 alpha | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:2005`；`Sources/SnapLex/Snipaste/SnipastePinManager.swift:1021` |
| VIS-02 | 无主体/透明图/处理途中连续点效果或关闭 | 有明确结果/错误；无无限忙、重复窗；关闭后旧结果不得重开 | 同上 |
| VIS-03 | QR、条码、多码、无码、模糊码；分别点击扫描 | 成功剪贴板精确 payload，多码顺序与数量可核验；失败有提示且能继续截图 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:2031` |
| VIS-04 | 未锁定选区触发扫码 | 提示先框选，不崩溃、不读取不明确区域 | 同上 |
| VIS-05 | 固定多行文字图点提取文字；等待抽屉→编辑→复制全部→关闭/重开 | OCR 文本与样本对照；剪贴板等于编辑后内容；缓存/重开行为可重复 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:899`、`:2111` |
| VIS-06 | 空图 OCR | 显示未识别到文字信息，可正常关闭抽屉 | 同上 |
| VIS-07 | Google/Apple 分别点翻译；混合语言、目标语言已相同、无字图 | 内容确实翻译并贴合区域，原文/译文可切；无字与同语言有明确提示 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:762` |
| VIS-08 | 翻译开→还原→再开 | 还原确实回原图；缓存重用行为正确；不重复增加学习记录 | 同上 |
| VIS-09 | 翻译途中还原/关闭/应用效果，再等待旧请求结束 | 旧结果不覆盖新状态、不重开窗口；错误可再次发起 | 同上 |
| VIS-10 | 完成后抽屉看原文/译文、复制全部；截图翻译记录开关 on/off | 两种文本精确匹配，记录开关生效；无隐式重复记录 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:1280`、`:2111` |

## PIN：贴图逐按钮与隐藏入口

| ID | 控件/入口与操作 | 可观测预期 | 源码 |
|---|---|---|---|
| PIN-01 | 剪贴板图像、文字、`#RRGGBB`、空剪贴板分别贴图 | 图像/文字/色卡正确；空输入无异常 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:345`、`:401` |
| PIN-02 | 缩小/放大分别点至边界；滚轮重复 | 缩放限制 15%–400%；图像比例、工具栏锚点正确 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:930` |
| PIN-03 | Option+滚轮调透明度到上下界；点 1:1/按 0 | 透明度 15%–100%；复位同时回 100% 大小和不透明 | 同上 |
| PIN-04 | 旋转按钮、右键旋转、R 分别操作；四次还原 | 图像方向正确，宽高随旋转更新；保存方向一致 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:1014` |
| PIN-05 | 右键镜像/H 各操作；两次还原 | 图像水平翻转；保存/复制也正确 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:1050` |
| PIN-06 | 阴影按钮与右键各开/关 | 实际窗口阴影随状态变化，不只按钮高亮 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:712` |
| PIN-07 | 标注按钮/右键各开/关 | 子栏出现/消失；图像拖动与标注拖动符合当前模式；输入先提交 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:698` |
| PIN-08 | 穿透按钮/右键开→点下方测试控件→点“退出穿透” | 点击确实穿透；退出按钮始终可点击并恢复不透明/交互 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:1059` |
| PIN-09 | 四角位置、拖动、缩放后开穿透；隐藏全部/恢复；解除全部穿透 | 退出 pill 随贴图定位，无遗留辅助窗；全解除有效 | 同上、`:385` |
| PIN-10 | 右键折叠/展开、双击各执行；缩略图拖动 | 折叠为 54×54；展开恢复尺寸；标注中禁止折叠，缩略态旋转 guard 行为明确 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:999` |
| PIN-11 | 复制按钮、右键复制、⌘C；保存按钮、右键保存、⌘S | 每入口输出正确；PNG 包含实际标注、透明度语义、旋转/镜像；取消无目标文件 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:1131` |
| PIN-12 | 关闭按钮、右键关闭、Esc、Delete 各关闭 | 图像及工具栏/抽屉/退出 pill 都消失；可恢复最近关闭 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:358`、`:1159` |
| PIN-13 | 多贴图 A/B/C；隐藏/显示全部、关闭全部、逐个恢复；关闭 26 个 | 顺序与最新优先相符，关闭历史上限 25；伴随窗随管理动作消失/恢复 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:358` |
| PIN-14 | 悬停图像→跨 6pt 间隙进工具栏→连续缩放；开 OCR 抽屉 | 工具栏不闪失/重叠，仍对齐图片而非抽屉；每按钮 tooltip 可辨识 | `Sources/SnapLex/Snipaste/SnipastePinManager.swift:626`、`:899` |

所有右键同名项须独立点选一次，不以主栏通过代替。贴图快捷键清单：R/H/T/0、⌘C/⌘S/⌘Z/⌘⇧Z、Delete、Esc（`SnipastePinManager.swift:1159`）。

## SCR：长截图完整路径

| ID | 操作 | 可观测预期 | 源码 |
|---|---|---|---|
| SCR-01 | 编号长页面下滚 5 屏→上滚 2 屏→下滚到新内容→完成 | 连续编号无重复/缺行，固定顶栏/左右色标无错误拼接；比例不压缩 | `Sources/SnapLex/Snipaste/ScrollingCaptureEngine.swift:304` |
| SCR-02 | 点自动滚动→停止→重启→Space→重启→移出选框→重启→点击 | 每种暂停入口确实停滚且状态文字/图标一致，仍能手动继续 | `Sources/SnapLex/Snipaste/ScrollingCaptureEngine.swift:129`、`:153`、`:201` |
| SCR-03 | 页顶/底反复滚、静态页面、惯性快滚、少量横向漂移、窗口遮挡 | 不凭空追加重复图；失败可停/取消；拼接结果有证据可查 | 同上 |
| SCR-04 | 点完成、Enter/小键盘 Enter 分别完成 | 剪贴板图像、贴图、截图历史一致；无辅助窗残留 | `Sources/SnapLex/Snipaste/ScrollingCaptureEngine.swift:240` |
| SCR-05 | 点取消、Esc 分别退出 | 结束捕获与自动滚动，无额外完成结果；能立即重开 | `Sources/SnapLex/Snipaste/ScrollingCaptureEngine.swift:267` |
| SCR-06 | 重新进入并观察 | 预览/计数归零，旧定时器不继续滚动原窗口 | `Sources/SnapLex/Snipaste/ScrollingCaptureEngine.swift:65` |

## REC：录屏设置、控制与导出

| ID | 操作 | 可观测预期 | 源码 |
|---|---|---|---|
| REC-01 | 区域/窗口/全屏各录一次；窗口列表选中与直接点窗口两入口 | 选区与成片对应；窗口列表最多前 10 项，选中标记正确 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:712`、`:2407` |
| REC-02 | 全屏→区域；满高度区域展开录屏栏 | 区域重建合理，工具栏不出屏，不误录更大范围 | `Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:690` |
| REC-03 | 0/3/5s 分别开始；倒计时中结束/Esc | 倒计时和实际开始对应；取消无录屏残留；可再次开始 | `Sources/SnapLex/Snipaste/ScreenRecorderAssistant.swift:100` |
| REC-04 | 连续开始、录制中再开始、finalizing 时再开始 | 不启动并行 pipeline；结束/导出后能正常再次开始 | 同上 |
| REC-05 | 指针、点击波纹、按键显示分别 on/off；录专用测试动作 | 成片逐项显示/隐藏，按键文本准确且不含用户内容 | `Sources/SnapLex/Snipaste/ScreenCaptureRecordingPipeline.swift:85` |
| REC-06 | 系统声音/麦克风分别 off/on，录专用提示音 | 输出音轨及实际声音与设置一致，无意外录入 | 同上 |
| REC-07 | 录 3s→暂停 2s→继续 3s→结束 | 暂停计时不增，成片去掉暂停片段，音画同步，无黑帧 | `Sources/SnapLex/Snipaste/ScreenRecorderAssistant.swift:181` |
| REC-08 | 结束按钮、F10、Esc 各结束；录制中截图后继续 | 各入口可结束并导出；截图不意外终止录制 | `Sources/SnapLex/Snipaste/ScreenRecorderAssistant.swift:188`、`:200` |
| REC-09 | MP4/GIF 各保存；改文件名后切格式 | 扩展名随格式；输出可播放、尺寸/时长/方向正确；GIF 动画有效 | `Sources/SnapLex/Snipaste/ScreenRecorderAssistant.swift:336` |
| REC-10 | 保存取消、新建目录、同名覆盖（专用目录） | 取消清理临时录屏；覆盖仅目标文件；不残留错误状态 | 同上 |
| REC-11 | 专用环境中麦克风/屏幕权限拒绝、显示器消失、无帧、不可写目录 | 清晰错误、清理控制窗/定时器、可以重试；不能只相信成功 HUD | `Sources/SnapLex/Snipaste/ScreenRecorderAssistant.swift:237` |
| REC-12 | 窗口模式录制时移动/遮挡窗口 | 记录实际是否跟随/是否录入遮挡；按明确产品约定判定，不能预设单窗口捕获 | `Sources/SnapLex/Snipaste/ScreenCaptureRecordingPipeline.swift:101` |

## 优先实测的源码风险（尚未证实为运行缺陷）

1. 贴图 `mosaic/blur` 当前均绘制半透明灰色矩形，输出也用这套绘制：`Sources/SnapLex/Snipaste/SnipastePinManager.swift:2061`。必须检查带字图片真实效果，不能只验工具选中。
2. 窗口录制实际使用显示器 filter 加固定 sourceRect，没有独立 window content filter：`Sources/SnapLex/Snipaste/ScreenCaptureRecordingPipeline.swift:101`。移动/遮挡目标窗口是必要用例。
3. 关闭后恢复只保存 originalImage 与 frame，没有保存标注、旋转、镜像、透明度：`Sources/SnapLex/Snipaste/SnipastePinManager.swift:358`。复合贴图恢复状态需核验。
4. 贴图效果取 originalImage，不先 flatten 标注；效果后翻译缓存失效但已有标注仍在：`Sources/SnapLex/Snipaste/SnipastePinManager.swift:1021`。需要标注→效果→翻译组合用例。
5. PNG 保存有 `try?`，失败可能静默：`Sources/SnapLex/Snipaste/SnipasteCaptureOverlay.swift:2109`、`Sources/SnapLex/Snipaste/SnipastePinManager.swift:1153`。保存后必须打开产物检查。

## 相对现有计划的补充

`docs/testing/desktop-test-plan.md` 的 APP-141–200 仅按大功能列范围；`snaplex-regression-plan-zh.md` 已强调真实 UI 及隔离，但没有逐控件覆盖账。主要缺口是：10 种工具分别执行全生命周期、截图/贴图两实现分别验证、贴图右键独有镜像/折叠、透明度手势、穿透退出 pill、长截图暂停变体、录屏所有设置的成片核对、保存取消后的历史副作用，以及源代码疑点的针对性输出检查。本文只补计划依据，不把历史逻辑测试通过折算成这些桌面场景通过。
