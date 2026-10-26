# 提词器 NotchCue

中文优先的 MacBook 提词器，挂在刘海下面。你读到哪个字，那个字就停在摄像头正下方。

录视频、上网课、开视频会议时看稿子，普通提词器是一整段字，眼睛要从左扫到右、一行行往下移，对面的人看得出你在读稿。这个提词器把**下一个要读的字固定在摄像头正下方**，后面的字一个接一个流过来，读过的往左淡出。眼睛一直盯着镜头下面同一个点，看起来就是在直视镜头。

基于开源提词器 [Textream](https://github.com/f/textream) 改造，见文末[致谢与许可](#致谢与许可)。

## 功能

**刘海锚点模式**

- 单行显示，黑条从刘海挂下来，和刘海连成一片；没有刘海的屏幕显示在屏幕正中。
- 下一个要读的字对准摄像头，右边提前显示后面 8–20 个字，越远越淡。
- 字跟着你的声音“流”过来，不会一跳一跳：识别结果一阵一阵到，显示以有上限的速度追上去（默认 8 字/秒）；你跳过一句时，0.25 秒快速滑过去。
- 字号、预读字数、推进速度上限都能调，设置窗口里能实时预览。

**中文逐字跟随**

- 同音字也能对上：稿子和识别结果都转成拼音比对，「期中」被识别成「期终」照样往前走；常用多音字（行、乐、觉、重…）的各个读音都算。
- 数字怎么读都行：稿子写「2026」，读「二零二六」「两千零二十六」都能对上；十一、一百一十、三点五、百分之五十同理，反过来稿子写汉字、识别出阿拉伯数字也行。
- 中英混读：稿子里的英文单词照常跟随。
- 即兴插话光标不动，回到稿子接着跟；跳过一句，读出后面连续几个字就接上。
- 识别结果中途改写也不会让光标倒退。
- 可选模糊音：z/zh、c/ch、s/sh、n/l、an/ang、en/eng、in/ing 视为同音，默认关。

**控制**

| 快捷键 | 作用 |
|---|---|
| ⌃⌥P | 暂停 / 继续 |
| ⌃⌥← | 回退一个短句（句中回到本句开头，句首回到上一句） |
| ⌃⌥→ | 前进到下一个短句 |

快捷键全局有效，在别的程序里录屏、开会时也能按；只在提词器打开期间占用，关掉就释放。点任意一个字可以直接跳过去。

**原版 Textream 的功能都保留**：多行刘海模式、浮动窗口、全屏、外接显示器与提词镜像、网页遥控、导演模式、从 PowerPoint 备注导入、共享屏幕时隐藏。英文等其他语言沿用原版的跟随算法，行为不变。

## 系统要求

- macOS 15 或更新，Apple 芯片和 Intel 的 Mac 都能用；带刘海的 MacBook 效果最好。
- 需要「麦克风」和「语音识别」权限。识别用的是 Apple 的 Speech 框架，音频可能由 Apple 处理，见 [SECURITY.md](SECURITY.md)。

## 安装

### 直接下载

1. 到 [Releases](https://github.com/wojiaozyh123-hub/notchcue/releases/latest) 下载最新版本：`NotchCue-x.y.z.dmg` 或 `NotchCue-x.y.z.zip`，哪个都行。
2. DMG：双击打开，把 **NotchCue** 拖进「应用程序」文件夹。ZIP：双击解压（Safari 下载后会自动解压），把 **NotchCue** 拖进「应用程序」文件夹。
3. 在「应用程序」里双击 NotchCue 打开。
4. 第一次开始提词时，允许麦克风和语音识别权限。

### 第一次打开被系统拦住怎么办

app 已经用开发者证书签名，但 **Apple 公证还在审核中**，所以第一次打开时 macOS 会提示「Apple 无法验证 NotchCue 是否包含恶意软件」。这只需要放行一次，之后就能正常打开：

1. 在提示框里点「**完成**」（不要点「移到废纸篓」）。
2. 打开「**系统设置**」→「**隐私与安全性**」，往下翻到「安全性」那一栏，会看到「已阻止使用 NotchCue……」。
3. 点它旁边的「**仍要打开**」，输入电脑密码确认，再在弹出的提示里点「**仍要打开**」。

也可以在「终端」里运行下面这一行，效果一样：

```bash
xattr -dr com.apple.quarantine /Applications/NotchCue.app
```

公证通过后会换上公证版，到时候就不用这一步了。

### 从源码编译

需要 Xcode 26 或更新：

1. 克隆仓库：
   ```bash
   git clone https://github.com/wojiaozyh123-hub/notchcue.git
   ```
2. 用 Xcode 打开 `Textream/Textream.xcodeproj`。
3. 选中 **Textream** target → Signing & Capabilities → Team 改成你自己的开发者账号（仓库里填的是作者的团队）。
4. Scheme 选 **Textream**，目标选 **My Mac**，按 ⌘R。
5. 第一次开始提词时，允许麦克风和语音识别权限。

## 使用

1. **放入稿子**：在主窗口粘贴稿子，或 ⌘O 打开 `.notchcue` 文件（原版的 `.textream` 文件和 PowerPoint `.pptx` 备注也能打开）。可以分多页。
2. **选跟随方式**：设置 → Guidance 选 **Word Tracking**（逐字跟随），语言默认中文（中国大陆）。
3. **选显示方式**：设置 → Teleprompter 选 **刘海锚点**，调字号、预读字数、推进速度上限。
4. **开始**：按 ⌘↩，对着麦克风读就行。
5. **结束**：读完最后一个字会自动收起；中途结束可以先点一下黑条再按 Esc，或在主窗口停止。

写稿子的小建议：

- 用标点断句。短句跳转（⌃⌥← / ⌃⌥→）按标点切分。
- 方括号里的是提示，比如 `[停顿]` `[看镜头]`，会淡淡地显示出来，不用读，也不影响跟随。
- 数字写阿拉伯数字还是汉字都可以。

## 用录音反复测试

菜单「调试」里有两个入口，用音频文件代替麦克风，读当前这一页稿子：

- **用音频文件快速跑一遍…**：交给 Apple 的文件识别，几秒跑完一整段录音，适合出日志。
- **按实际速度回放音频文件…**：把录音按真实速度播放，走和麦克风完全一样的流程，能看到刘海上字怎么流。

每次跑完会保存一份日志（每条识别结果和光标位置），并在 Finder 里打开它所在的文件夹：发布版在 `~/Library/Application Support/app.notchcue.mac/DebugRuns/`，从 Xcode 运行的开发版在 app 的沙盒容器里（`~/Library/Containers/app.notchcue.mac/Data/Library/Application Support/app.notchcue.mac/DebugRuns/`）。

把日志放进 `Textream/Packages/PrompterCore/Tests/PrompterCoreTests/Fixtures/`，就会变成一条回放这段真实录音的回归测试。`debug-samples/` 里有一份示例稿子和两段录音（照读一遍；带即兴插话并跳过一句）。

## 工作原理

- **切词**：一个汉字、一个英文单词、一个数字各算一个单位，标点只用来断句。显示用的字符位置和匹配用的单位之间有一张映射表，所以各个显示模式、外接屏、网页遥控读的都是同一个进度。
- **对齐**：每条识别结果只取最后约 30 个单位，在光标前 8 个、后 40 个的范围里做局部对齐；同字、同音、数字读法都算对上。只有对上了最新说出的那个字，光标才往前走，所以插话不会把光标带跑。中间跳过的字越多，要求越严：跳过 2 个以内，结尾连续对上 2 个就行；跳过 3–8 个要连续对上 3 个；跳过更多还要再等一条结果确认。
- **显示**：显示位置以有上限的速度追识别位置；点字、快捷键、换页直接到位。

## 开发

- 对齐、拼音、数字读法、平滑推进、锚点位置这些纯逻辑都在本地 Swift 包 `Textream/Packages/PrompterCore` 里，不依赖麦克风，能单独测：
  ```bash
  cd Textream/Packages/PrompterCore && swift test
  ```
- 测试覆盖同音字、漏读一句、即兴插话、各种数字写法、中英混读、识别结果回改（都会检查光标只进不退），以及原版英文算法的回归结果。
- 仓库里的 iOS target（`TextreamiOS`）是原版的，没有改动。
- 打发布包：`cd Textream && NOTARY_PROFILE=<公证凭据名> ./build.sh`。脚本会打出双架构、用 Developer ID 签名的 app，提交 Apple 公证并把结果钉进 app 和 DMG。签名走 Xcode 的自动签名，用的是本机的 Developer ID 证书或 Apple 云端托管的证书，Xcode 里要登录团队账号。公证凭据先用 `xcrun notarytool store-credentials` 存一次。

## 已知限制

- 光标落后说话位置超过 40 个字（比如整段跳过）就接不回来，需要点一下要读的字。
- ⌃⌥← / ⌃⌥→ 可能被 Rectangle 这类窗口管理工具占用。
- 经典（匀速滚动）模式下，外接显示器有自己的计时，不跟快捷键同步。

## 致谢与许可

- 基于 [Textream](https://github.com/f/textream)，作者 Fatih Kadir Akın，原始想法来自 Semih Kışlar，MIT 许可。
- 内置字体 OpenDyslexic 使用 SIL Open Font License 1.1，见 `Textream/Textream/Fonts/OpenDyslexic-OFL.txt`。
- 本项目同样以 MIT 许可发布，见 [LICENSE](LICENSE)。

---

## English

**NotchCue (提词器)** is a Chinese-first teleprompter for the MacBook notch, forked from [Textream](https://github.com/f/textream). In its anchor mode the next word to read always sits right under the camera while the rest of the script flows toward it, so your eyes stay on the lens. Speech following is rebuilt for Mandarin: matching by pinyin (homophones and common polyphones), spoken forms of numbers, mixed Chinese and English, ad-libs that don't move the cursor, and skipped sentences that are picked up again. Global shortcuts: ⌃⌥P pause, ⌃⌥← / ⌃⌥→ previous / next phrase. Other languages keep Textream's original follower unchanged.

Download the DMG or ZIP from [Releases](https://github.com/wojiaozyh123-hub/notchcue/releases/latest) (macOS 15+, Apple silicon and Intel). The app is signed with Developer ID; Apple notarization is still pending, so on first launch choose Done, then System Settings → Privacy & Security → Open Anyway. Or build from source with Xcode 26: open `Textream/Textream.xcodeproj`, set your own signing team, run the **Textream** scheme. Alignment logic and its tests live in `Textream/Packages/PrompterCore` (`swift test`). MIT licensed, like Textream.
