#!/bin/bash
# Builds search-one-shape.mp4: a 14 s, 1440×1440, 60 fps loop of index.html,
# with seven bars of "Swish Swed" (Arulo, Mixkit) and UI sounds on their
# events.
#
#   ./build.sh           everything
#   ./build.sh beats     just one PNG per beat, into out/beats, to check
#
# Needs Node with Playwright, Python 3 with numpy and imageio-ffmpeg
# (pip install numpy imageio-ffmpeg). The music and sounds are Mixkit's, free
# to use in a video under their licence (mixkit.co/license) but not ours to
# redistribute, so they are fetched into cache/ rather than kept here.
set -euo pipefail
cd "$(dirname "$0")"
FF=$(python3 -c "import imageio_ffmpeg; print(imageio_ffmpeg.get_ffmpeg_exe())")

if [ "${1:-}" = beats ]; then
  node render.mjs beats out/beats 4
  exit
fi

mkdir -p cache out
fetch() { [ -s "cache/$1" ] || curl -fsSL -A 'Mozilla/5.0' -o "cache/$1" "$2"; }
fetch song.mp3   https://assets.mixkit.co/music/201/201.mp3                       # Swish Swed — Arulo
fetch click.mp3  https://assets.mixkit.co/active_storage/sfx/2568/2568-preview.mp3 # Cool interface click tone
fetch switch.mp3 https://assets.mixkit.co/active_storage/sfx/2585/2585-preview.mp3 # On or off light switch tap
fetch check.mp3  https://assets.mixkit.co/active_storage/sfx/1120/1120-preview.mp3 # Modern click box check
fetch key.mp3    https://assets.mixkit.co/active_storage/sfx/2541/2541-preview.mp3 # Single key press in a laptop
fetch pop.mp3    https://assets.mixkit.co/active_storage/sfx/2356/2356-preview.mp3 # Dry pop up notification alert

python3 audio.py cache out/mix.wav
node render.mjs frames out/subs 6
# Four subframes per frame, averaged: motion blur at 60 fps.
"$FF" -loglevel error -y -framerate 240 -i out/subs/sub-%05d.png -i out/mix.wav \
  -filter_complex "[0:v]tmix=frames=4:weights='1 1 1 1',select='eq(mod(n\,4)\,3)',setpts=N/60/TB,format=yuv420p[v]" \
  -map "[v]" -map 1:a -r 60 -c:v libx264 -preset slow -crf 14 -movflags +faststart -c:a aac -b:a 256k -shortest \
  search-one-shape.mp4
echo "wrote promo/search-one-shape.mp4"
