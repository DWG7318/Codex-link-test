#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="$ROOT_DIR/input"
ASSETS_DIR="$ROOT_DIR/assets"
OUTPUT_DIR="$ROOT_DIR/output"
TMP_DIR="$ROOT_DIR/tmp"
TOOLS_DIR="$ROOT_DIR/tools"
PIPER_BIN="$TOOLS_DIR/piper/piper"
WHISPER_BIN="$TOOLS_DIR/whisper.cpp/build/bin/whisper-cli"
WHISPER_MODEL_BASE="$ROOT_DIR/models/whisper/ggml-base.bin"
WHISPER_MODEL_TINY="$ROOT_DIR/models/whisper/ggml-tiny.bin"

TOPIC_FILE="$INPUT_DIR/topic.txt"
OUTLINE_FILE="$INPUT_DIR/outline.md"
BGM_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topic-file)
      TOPIC_FILE="$2"; shift 2 ;;
    --outline)
      OUTLINE_FILE="$2"; shift 2 ;;
    --bgm)
      BGM_FILE="$2"; shift 2 ;;
    *)
      echo "Unknown arg: $1"; exit 1 ;;
  esac
done

mkdir -p "$OUTPUT_DIR" "$TMP_DIR"

SCRIPT_MD="$OUTPUT_DIR/script.md"
AUDIO_A="$OUTPUT_DIR/audio_a.wav"
AUDIO_B="$OUTPUT_DIR/audio_b.wav"
MIX_WAV="$OUTPUT_DIR/mix.wav"
SUBS_SRT="$OUTPUT_DIR/subs.srt"
FINAL_MP4="$OUTPUT_DIR/final.mp4"
COVER_JPG="$OUTPUT_DIR/cover.jpg"
CAPTION_TXT="$OUTPUT_DIR/caption.txt"

BG_IMG="$ASSETS_DIR/background.png"
AVATAR_A="$ASSETS_DIR/avatar_a.png"
AVATAR_B="$ASSETS_DIR/avatar_b.png"

pick_voice() {
  local preferred="$1"
  local fallback="$2"
  if [[ -f "$preferred" ]]; then
    echo "$preferred"
  else
    echo "$fallback"
  fi
}

VOICE_A=$(pick_voice "$ROOT_DIR/models/piper/zh_CN-huayan-medium.onnx" "$ROOT_DIR/models/piper/en_US-amy-medium.onnx")
VOICE_B=$(pick_voice "$ROOT_DIR/models/piper/zh_CN-huayan-high.onnx" "$ROOT_DIR/models/piper/en_US-ryan-medium.onnx")

WHISPER_MODEL="$WHISPER_MODEL_BASE"
[[ -f "$WHISPER_MODEL" ]] || WHISPER_MODEL="$WHISPER_MODEL_TINY"

for need in "$TOPIC_FILE" "$OUTLINE_FILE" "$PIPER_BIN" "$WHISPER_BIN" "$VOICE_A" "$VOICE_B" "$WHISPER_MODEL"; do
  [[ -f "$need" ]] || { echo "Missing required file: $need"; exit 1; }
done

if [[ ! -f "$BG_IMG" ]]; then
  ffmpeg -y -f lavfi -i color=c=0x1f2937:s=1920x1080:d=1 -frames:v 1 "$BG_IMG" >/dev/null 2>&1
fi
if [[ ! -f "$AVATAR_A" ]]; then
  ffmpeg -y -f lavfi -i color=c=0x93c5fd:s=512x512:d=1 -frames:v 1 "$AVATAR_A" >/dev/null 2>&1
fi
if [[ ! -f "$AVATAR_B" ]]; then
  ffmpeg -y -f lavfi -i color=c=0xf9a8d4:s=512x512:d=1 -frames:v 1 "$AVATAR_B" >/dev/null 2>&1
fi

python3 - <<'PY' "$TOPIC_FILE" "$OUTLINE_FILE" "$SCRIPT_MD" "$CAPTION_TXT"
import re
import sys
from pathlib import Path

topic = Path(sys.argv[1]).read_text(encoding='utf-8').strip()
outline = Path(sys.argv[2]).read_text(encoding='utf-8').splitlines()
script_out = Path(sys.argv[3])
caption_out = Path(sys.argv[4])

points = [re.sub(r'^[-*#\d.\s]+', '', x).strip() for x in outline if x.strip()]
if not points:
    points = ["什么是这个主题", "核心原理", "常见误区", "生活中的应用", "总结"]

def line_for(idx, point, speaker):
    if speaker == 'A':
        return f"- Speaker A: 我们来聊聊{topic}，这一段聚焦“{point}”。[pace=normal][pause=600ms]"
    return f"- Speaker B: 好的，我补充一个易懂版本：{point} 的关键是把复杂问题拆成可验证的小步骤。[pace=normal][pause=800ms]"

lines = [
    f"# Topic\n{topic}\n",
    "# Dialogue Script (5-10 min target)",
    "",
    "- Speaker A: 大家好，今天我们做一期科普对话。[pace=slow][pause=700ms]",
    "- Speaker B: 我会用生活化例子帮助你快速理解。[pace=normal][pause=700ms]",
]

for i, p in enumerate(points * 2):
    sp = 'A' if i % 2 == 0 else 'B'
    lines.append(line_for(i, p, sp))

lines += [
    "- Speaker A: 最后做个总结，建议你把今天的要点记成三条清单。[pace=normal][pause=700ms]",
    "- Speaker B: 如果你想看下一期，欢迎留言告诉我们你最想听的主题。[pace=normal][pause=1000ms]",
]

script_out.write_text("\n".join(lines) + "\n", encoding='utf-8')

hashtags = "#科普 #知识分享 #AI #效率 #学习方法"
caption_out.write_text(
    f"[Douyin]\n标题：3分钟听懂{topic}\n文案：这期我们用双人对话拆解{topic}，适合通勤/睡前速听。\n{hashtags}\n\n"
    f"[TikTok]\nTitle: Understand {topic} in minutes\nCaption: Two-host explainer with practical examples and takeaways.\n#science #learnontiktok #explainer #productivity\n",
    encoding='utf-8'
)
PY

python3 - <<'PY' "$SCRIPT_MD" "$TMP_DIR"
import re
import sys
from pathlib import Path

script = Path(sys.argv[1]).read_text(encoding='utf-8').splitlines()
out = Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)

seq = []
a_lines = []
b_lines = []
idx = 0
for ln in script:
    m = re.match(r"-\s*Speaker\s+([AB]):\s*(.*)", ln.strip())
    if not m:
        continue
    spk, text = m.group(1), m.group(2)
    pause = 500
    pm = re.search(r"\[pause=(\d+)ms\]", text)
    if pm:
        pause = int(pm.group(1))
    clean = re.sub(r"\[(pace|pause)=[^\]]+\]", "", text).strip()
    if not clean:
        continue
    rec = f"{idx:03d}|{spk}|{pause}|{clean}"
    seq.append(rec)
    (a_lines if spk == 'A' else b_lines).append(clean)
    idx += 1

(out / "sequence.txt").write_text("\n".join(seq) + "\n", encoding='utf-8')
(out / "speaker_a.txt").write_text("\n".join(a_lines) + "\n", encoding='utf-8')
(out / "speaker_b.txt").write_text("\n".join(b_lines) + "\n", encoding='utf-8')
PY

"$PIPER_BIN" --model "$VOICE_A" --output_file "$AUDIO_A" < "$TMP_DIR/speaker_a.txt"
"$PIPER_BIN" --model "$VOICE_B" --output_file "$AUDIO_B" < "$TMP_DIR/speaker_b.txt"

rm -f "$TMP_DIR/concat_list.txt"
while IFS='|' read -r idx spk pause text; do
  seg_txt="$TMP_DIR/${idx}_${spk}.txt"
  seg_wav="$TMP_DIR/${idx}_${spk}.wav"
  sil_wav="$TMP_DIR/${idx}_sil.wav"
  printf '%s\n' "$text" > "$seg_txt"
  if [[ "$spk" == "A" ]]; then
    "$PIPER_BIN" --model "$VOICE_A" --output_file "$seg_wav" < "$seg_txt"
  else
    "$PIPER_BIN" --model "$VOICE_B" --output_file "$seg_wav" < "$seg_txt"
  fi
  ffmpeg -y -f lavfi -i anullsrc=r=22050:cl=mono -t "$(awk "BEGIN {print $pause/1000}")" "$sil_wav" >/dev/null 2>&1
  printf "file '%s'\n" "$seg_wav" >> "$TMP_DIR/concat_list.txt"
  printf "file '%s'\n" "$sil_wav" >> "$TMP_DIR/concat_list.txt"
done < "$TMP_DIR/sequence.txt"

ffmpeg -y -f concat -safe 0 -i "$TMP_DIR/concat_list.txt" -c copy "$TMP_DIR/dialogue.wav" >/dev/null 2>&1 || \
ffmpeg -y -f concat -safe 0 -i "$TMP_DIR/concat_list.txt" "$TMP_DIR/dialogue.wav" >/dev/null 2>&1

if [[ -n "$BGM_FILE" && -f "$BGM_FILE" ]]; then
  ffmpeg -y -stream_loop -1 -i "$BGM_FILE" -i "$TMP_DIR/dialogue.wav" -filter_complex "[0:a]volume=0.08[bgm];[1:a]loudnorm=I=-16:TP=-1.5:LRA=11[vox];[bgm][vox]amix=inputs=2:duration=shortest" "$MIX_WAV" >/dev/null 2>&1
else
  ffmpeg -y -i "$TMP_DIR/dialogue.wav" -af "loudnorm=I=-16:TP=-1.5:LRA=11" "$MIX_WAV" >/dev/null 2>&1
fi

"$WHISPER_BIN" -m "$WHISPER_MODEL" -f "$MIX_WAV" -osrt -of "$OUTPUT_DIR/subs" -l auto >/dev/null 2>&1
[[ -f "$OUTPUT_DIR/subs.srt" ]] && mv "$OUTPUT_DIR/subs.srt" "$SUBS_SRT"

ffmpeg -y \
  -loop 1 -i "$BG_IMG" \
  -i "$AVATAR_A" \
  -i "$AVATAR_B" \
  -i "$MIX_WAV" \
  -filter_complex "
    [0:v]scale=1920:1080,setsar=1[bg];
    [1:v]scale=260:260,format=rgba,
      geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lte((X-130)*(X-130)+(Y-130)*(Y-130),130*130),255,0)'[a1];
    [2:v]scale=260:260,format=rgba,
      geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lte((X-130)*(X-130)+(Y-130)*(Y-130),130*130),255,0)'[a2];
    [bg][a1]overlay=160:720[tmp1];
    [tmp1][a2]overlay=1500:720[vout]
  " \
  -map "[vout]" -map 3:a -c:v libx264 -tune stillimage -c:a aac -shortest \
  -vf "subtitles='$SUBS_SRT':force_style='FontName=DejaVu Sans,Fontsize=24,PrimaryColour=&H00FFFFFF,OutlineColour=&H00000000,BorderStyle=3,MarginV=40'" \
  "$FINAL_MP4" >/dev/null 2>&1

ffmpeg -y -i "$FINAL_MP4" -vf "select=eq(n\,0)" -q:v 2 -frames:v 1 "$COVER_JPG" >/dev/null 2>&1 || \
ffmpeg -y -i "$BG_IMG" -q:v 2 "$COVER_JPG" >/dev/null 2>&1

echo "Done:"
echo "  $SCRIPT_MD"
echo "  $AUDIO_A"
echo "  $AUDIO_B"
echo "  $MIX_WAV"
echo "  $SUBS_SRT"
echo "  $FINAL_MP4"
echo "  $COVER_JPG"
echo "  $CAPTION_TXT"
