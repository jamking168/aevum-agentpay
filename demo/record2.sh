#!/usr/bin/env bash
# Re-record the demo with the capture started BEFORE the page, then cut the magenta
# slate off the front. The stock builder waits up to 30 s for a 1440x900 window before
# it starts ffmpeg; on this host that probe never matches, so the page ran ~30 s ahead
# of the recording and every scene showed the next scene's subtitle.
set -uo pipefail

DEMO=/home/jam/projects/money-coo/aevum-challenge/demo
SKILL=/home/jam/.hermes/profiles/money-coo/skills/media/demo-video-production/scripts
export DISPLAY=:98   # dedicated display: nothing else can raise a window over the page
PAGE="file://$DEMO/demo.html"
# A private Xvfb display, so the long-lived CDP browser cannot pop up over the recording.
if ! xdpyinfo -display :98 >/dev/null 2>&1; then
  Xvfb :98 -screen 0 1440x900x24 -nolisten tcp >/dev/null 2>&1 &
  sleep 2
fi
TOTAL=86.5
GATE=4
TAIL=8
RAWLEN=$(python3 -c "print(round($TOTAL + $TAIL, 1))")
PROFILE=/tmp/demo-chrome-slate
rm -rf "$PROFILE"; rm -f "$DEMO/recording2.mp4"

cd "$DEMO" || exit 1

# 1. start the capture first
ffmpeg -y -loglevel error -f x11grab -video_size 1440x900 -framerate 25 -draw_mouse 0 \
  -i :98 -t "$RAWLEN" -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p \
  recording2.mp4 &
REC=$!
sleep 1

# 2. then the kiosk page (its first paint is a magenta slate)
google-chrome --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check \
  --disable-session-crashed-bubble --hide-scrollbars --force-device-scale-factor=1 \
  --window-position=0,0 --window-size=1440,900 --kiosk "$PAGE" \
  >/dev/null 2>&1 &
CHROME=$!

sleep "$(python3 -c "print(round($TOTAL + $GATE + 3, 1))")"
kill "$CHROME" 2>/dev/null
wait "$REC" 2>/dev/null

# 3. cut the launch latency by finding the last magenta frame
CUT=$(python3 "$SKILL/detect_slate_cut.py" recording2.mp4 2>/dev/null | grep -oE "[0-9]+\.[0-9]+" | head -1)
echo "slate cut at: ${CUT:-unknown}s"
if [ -z "${CUT:-}" ]; then echo "ABORT: no slate boundary found"; exit 1; fi

# 4. trim + mux narration in one pass, then burn the subtitles
ffmpeg -y -loglevel error -ss "$CUT" -i recording2.mp4 -i narration_full.mp3 \
  -t "$TOTAL" -map 0:v -map 1:a -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p \
  -c:a aac -b:a 160k -movflags +faststart agentpay-demo.mp4

STYLE="FontName=DejaVu Sans,FontSize=11,PrimaryColour=&H00FFFFFF,OutlineColour=&HA0000000,BorderStyle=3,Outline=1,Shadow=0,MarginV=18,Bold=0"
ffmpeg -y -loglevel error -i agentpay-demo.mp4 -vf "subtitles=subtitles.srt:force_style='$STYLE'" \
  -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -c:a copy -movflags +faststart \
  agentpay-demo-subtitled.mp4

ffprobe -v error -show_entries format=duration,size -of default=nw=1 agentpay-demo-subtitled.mp4