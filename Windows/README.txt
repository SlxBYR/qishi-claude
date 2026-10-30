栖时 · Claude Windows 2.2.1（build 25）

当前交互：Claude 娘拖动只移动角色；拖到屏幕边缘时静态贴边，不再播放探出、收回或挥手动画。Clawd 的贴边与悬停探出保持不变。
工作台只保留 Clawd 小螃蟹的像素动画，与 macOS 版共用同一组 GIF，随机播放，点一下换一段。
本次交付范围
本次只替换用户现有 macOS 应用的动画资源，不生成新的 Windows 应用或压缩包。此目录保留共享动画与 Windows 源码修复；现有 Windows 2.2.1 压缩包未更新。下述新增动画及窗口运动行为属于当前源码，不能视为已安装进旧 Windows 发布包。

运行
解压整个 Windows 压缩包，双击 Qishi Claude.exe。请保留目录内所有文件。
支持 Windows 10 22H2 / Windows 11 x64。ARM64 可使用 npm run build -- --arm64 单独构建。
桌面先显示 Claude 娘与 Clawd；右键角色或双击系统托盘小螃蟹打开工作台。

当前源码功能
• 与 macOS 版共用 CrossPet / Clawd 素材与动画资源。
• 贴边窗口移动可取消，使用内部小数坐标平滑推进；拖动接管即取消旧移动与延迟贴边回调，避免跳回旧位置。
• Clawd 小螃蟹的素材、动画和交互保持不变。
• 支持透明双桌宠、拖动、点击、摇晃、眼神跟随、待机睡眠、屏幕贴边与位置保存。
• Windows 系统托盘、原生菜单、通知、窗口与多显示器适配。
• Claude 工作台、多个会话、额度、上下文、可选单次工具授权；浅色 / 深色 / 跟随系统与中文 / English 切换。
• Gmail 只读检查（全部邮件、垃圾邮件、已删除邮件）与账号计时。
• Gmail 应用专用密码仅由 Electron safeStorage 调用 Windows DPAPI 加密后本地存储；不会写入普通设置文件。

接入
在“桌宠与接入”点击“接入 Claude Code”，再重新打开 Claude Code 会话。
该操作保存原 settings.json 备份，保留其他钩子和设置；撤销接入会恢复未被后续修改的原状态栏。
桥接运行时复制到稳定的本机数据目录，移动解压后的应用不影响已接入路径。
数据：%LOCALAPPDATA%\QishiClaude
Claude 设置：%USERPROFILE%\.claude\settings.json（支持 CLAUDE_CONFIG_DIR）。
只支持 Windows 原生 Claude Code；WSL 会话使用不同的设置和文件系统，未建立 WSL 桥接。
不会读取 Claude 登录凭据，不会新增额度 API 调用，不会自动批准工具。
应用关闭、授权关闭、请求超时、会话完成或转入新一轮时，授权返回 Claude 原生流程。

源码构建（供日后开发；本次不构建）
安装 Node.js 22 或更新版本，进入 Windows 文件夹：
  npm ci
  npm test
  npm run build
输出在项目 outputs/Windows-build。开发预览：npm run demo。
本次不生成新的 Windows 压缩包；原有 2.2.1 包与校验值保持不变。
npm test 包含窗口运动回归：单调收敛、拖动接管、目标切换和过期贴边回调。共享的 Claude 娘静态贴边由 Qishi 目录的 bash Scripts/test.sh --motion-only 在真实 WebKit 中验证。
本项目使用固定版本 Electron 45.1.0 和 imapflow 2.10.0；安装依赖需要联网。
可选：设置环境变量 QISHI_ELECTRON_ZIP_DIR，指定已下载 Electron ZIP 所在目录，以复用本地安装包。目录内 ZIP 的版本、平台和架构须与本次构建一致，例如 electron-v45.1.0-win32-x64.zip；填写目录路径，不是 ZIP 文件路径。
--demo 与 --verify-ui 使用独立临时数据，不修改真实 Claude 设置或邮箱密码。

平台限制
可在 macOS 上运行 Windows 外壳的隔离预览并检查画面，但不代替 Windows 实机测试。
透明窗口、DPI、多屏、系统托盘、DPAPI、PowerShell、通知与窗口生命周期尚未在 Windows 实机确认。
未使用真实 Gmail 或 Claude 账号验收，也未进行真实账号的付费模型调用验收。

许可
原始素材及许可证保留在 resources/assets 中。
Claude 娘：CrossPet / lokicorvus，CC BY-NC-SA 4.0；新增拖动差分沿用原角色设定与素材授权。
Clawd：Clawd on Desk / rullerzhou-afk；美术资源权利由原权利人保留。
供个人本机使用；未经权利人授权，不公开分发包含相关素材的整合应用。
非 Anthropic 官方应用。
