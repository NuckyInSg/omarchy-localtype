# LocalType for Omarchy

[English](README.md)

LocalType 是一个本地优先的中文智能语音输入插件。它使用 [Qwen3-ASR-1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) 识别语音，再用 Qwen3-0.6B 保守地去除语气词、修正口误和补充标点。录音和文字默认不离开本机。

![LocalType 桌面工作台](assets/desktop-preview.png)

## 一键安装

```bash
omarchy plugin add https://github.com/NuckyInSg/omarchy-localtype.git --enable
```

插件会自动安装运行环境、模型、用户级 systemd 服务、桌面启动器和 Hyprland 快捷键。首次安装需要下载模型，可能耗时数分钟。

## 使用

| 默认快捷键 | 行为 |
|---|---|
| `F9` | 开始或停止智能听写 |
| `Shift+F9` | 开始或停止原文听写 |

插件只输入文字，不会代替你按回车、发送消息或执行终端命令。终端应用会通过一次整段粘贴接收文字，避免 Codex 等 TUI 把长文本拆成多次提交。

从 Omarchy 应用启动器、状态栏面板或命令行打开桌面应用：

```bash
localtypectl open
```

应用包含工作台、历史、个人词典、场景、模型和设置六个页面，并自动跟随当前 Omarchy 主题。

### 语言和快捷键

应用默认使用英文。在 **Settings → App language → 简体中文** 中可将桌面应用、状态栏面板和通知切换为中文。

在 **设置 → 快捷键** 中修改两个组合键，然后点击 **应用快捷键**。也可以使用命令：

```bash
localtypectl shortcuts-set "F9" "SHIFT + F9"
```

## 系统要求

- Omarchy 与 NVIDIA GPU；建议至少 6 GiB 显存
- 可用的 CUDA 驱动和麦克风
- 首次下载约需 5 GB 磁盘空间
- `uv`、PipeWire、`wtype`、`wl-copy`、`jq`、`curl` 和 `notify-send`

已在 RTX 5070 8 GiB 上验证，两个模型常驻时约占用 4.7–5.6 GiB 显存。

## 管理命令

```bash
localtypectl status
localtypectl doctor
localtypectl restart
localtypectl edit-dictionary
localtypectl open history
```

更新：

```bash
omarchy plugin update app.localtype.voice-input
```

卸载运行环境和插件并保留模型与个人数据：

```bash
localtypectl uninstall
omarchy plugin remove app.localtype.voice-input
```

一并删除全部模型与数据：

```bash
localtypectl uninstall --purge
omarchy plugin remove app.localtype.voice-input
```

## 本地数据

- 插件：`~/.config/omarchy/plugins/app.localtype.voice-input/`
- 模型与 Python 环境：`~/.local/share/localtype/`
- 个人词典：`~/.config/localtype/dictionary.json`
- 场景与设置：`~/.config/localtype/`
- 听写历史与状态：`~/.local/state/localtype/`
- 用户服务：`~/.config/systemd/user/localtype.service`

若检测到旧版 `~/.local/share/qwen3-asr/`，安装器会复用已有 Python 环境与模型缓存。

## 开发与校验

```bash
./scripts/check.sh
```

[MIT License](LICENSE)
