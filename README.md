# WSL2 半自动科普视频流水线（最小可跑通）

这是一个面向 **WSL2(Ubuntu)** 的离线优先流水线，自动从主题与大纲生成：

- `script.md`（双人对话稿，Speaker A/B，含语速与停顿标记）
- `audio_a.wav` / `audio_b.wav`（Piper TTS）
- `mix.wav`（FFmpeg 混音+响度统一）
- `subs.srt`（whisper.cpp 转字幕）
- `final.mp4`（固定背景 + 左右圆形头像 + 字幕烧录）
- `cover.jpg`（封面）
- `caption.txt`（抖音 + TikTok 文案）

> 工具仅使用：`ffmpeg`, `python3`, `whisper.cpp`, `piper-tts`。

---

## 目录结构

```text
.
├── assets/
│   └── README.md
├── input/
│   ├── outline.md
│   └── topic.txt
├── models/
│   ├── piper/            # install.sh 下载语音模型
│   └── whisper/          # install.sh 下载 ggml 模型
├── output/               # run.sh 产物目录
├── tmp/                  # run.sh 临时文件
├── tools/
│   ├── piper/            # piper 二进制
│   └── whisper.cpp/      # whisper.cpp 源码 + 编译产物
├── install.sh
├── run.sh
└── requirements.txt
```

---

## 一步一步运行

### 1) 安装依赖与模型

```bash
chmod +x install.sh run.sh
./install.sh
```

`install.sh` 会做这些事：

1. 安装系统依赖：`ffmpeg/python3/curl/git/cmake/build-essential`
2. 下载 `piper` Linux 二进制
3. 优先下载两套中文 Piper 音色（女+男）
4. 若中文音色不可用，自动下载英文 fallback 音色
5. 拉取并编译 `whisper.cpp`
6. 下载 `ggml-base.bin`（失败则回退 `ggml-tiny.bin`）

---

### 2) 准备输入

编辑：

- `input/topic.txt`：一个主题
- `input/outline.md`：5~8条要点

可选放入素材（见 `assets/README.md`）：

- `assets/background.png`
- `assets/avatar_a.png`
- `assets/avatar_b.png`
- `assets/bgm.mp3`（可选）

---

### 3) 运行主流程

无 BGM：

```bash
./run.sh --topic-file input/topic.txt --outline input/outline.md
```

带 BGM：

```bash
./run.sh --topic-file input/topic.txt --outline input/outline.md --bgm assets/bgm.mp3
```

---

## run.sh 产物说明

输出目录：`output/`

- `script.md`：自动生成对话稿，含 `[pace=...]` 与 `[pause=...ms]`
- `audio_a.wav`：A 角色全集合语音
- `audio_b.wav`：B 角色全集合语音
- `mix.wav`：按顺序拼接+停顿后输出，并做 loudnorm
- `subs.srt`：whisper.cpp 自动识别字幕
- `final.mp4`：固定画面合成视频（字幕烧录）
- `cover.jpg`：封面图（首帧/背景图）
- `caption.txt`：抖音与 TikTok 双份文案模板

---

## 语音与停顿规则

`script.md` 每行示例：

```md
- Speaker A: 这里是台词内容。[pace=normal][pause=800ms]
```

当前实现：

- `Speaker A/B` 决定使用哪个音色
- `[pause=800ms]` 会在该句后插入静音
- `[pace=...]` 目前只保留在文稿（便于后续扩展语速映射）

---

## 更换中文/其他音色

如果你想替换 Piper 模型：

1. 将新的 `*.onnx` + `*.onnx.json` 放到 `models/piper/`
2. 修改 `run.sh` 里的 `VOICE_A` / `VOICE_B` 选择路径
3. 重新执行 `./run.sh ...`

默认优先使用：

- `models/piper/zh_CN-huayan-medium.onnx`（A）
- `models/piper/zh_CN-huayan-high.onnx`（B）

若不存在，则自动回退到英文音色。

---

## 常见问题排查

### 1) `ffmpeg: command not found`

```bash
sudo apt-get update && sudo apt-get install -y ffmpeg
```

### 2) `Permission denied`（脚本不可执行）

```bash
chmod +x install.sh run.sh
```

### 3) `Missing required file: ...`

通常是模型或二进制未下载完整：

- 先重跑 `./install.sh`
- 检查：
  - `tools/piper/piper`
  - `tools/whisper.cpp/build/bin/whisper-cli`
  - `models/piper/*.onnx`
  - `models/whisper/ggml-base.bin` 或 `ggml-tiny.bin`

### 4) WSL 路径问题（Windows 路径混用）

建议始终在 Linux 路径中运行，例如：

```bash
cd /workspace/Codex-link-test
./run.sh --topic-file input/topic.txt --outline input/outline.md
```

### 5) 字幕识别慢

- 换 `ggml-tiny.bin`
- 降低音频时长
- 确保 WSL2 资源分配足够

---

## 备注

- 本项目避免桌面 UI 自动化，不包含上传动作。
- 这是“最小可跑通”版本：便于你后续加 LLM 写稿、分镜、多轨配乐、自动封面排版等能力。
