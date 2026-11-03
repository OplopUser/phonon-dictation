#!/bin/zsh
# Builds the streaming test and runs it on speech generated with macOS `say`.
# Uses the Phonon server on 127.0.0.1:8010 if one is running (the app's), or starts one.
set -euo pipefail
cd "${0:a:h}/.."
work=$(mktemp -d)
trap 'rm -rf "$work"; [[ -n "${server:-}" ]] && kill $server' EXIT

if ! curl -sf -o /dev/null http://127.0.0.1:8010/v1/models; then
  .venv/bin/phonon serve --port 8010 >/dev/null 2>&1 &
  server=$!
  # Same 3-minute limit the app uses; give up early if the server exits.
  for i in {1..180}; do
    curl -sf -o /dev/null http://127.0.0.1:8010/v1/models && break
    kill -0 $server 2>/dev/null || { echo "phonon serve exited during startup"; exit 1; }
    (( i == 180 )) && { echo "phonon serve did not start within 180 s"; exit 1; }
    sleep 1
  done
fi

swiftc -O -swift-version 5 Sources/Recorder.swift Sources/Streamer.swift Sources/Transcriber.swift Sources/Paster.swift Tests/main.swift -o "$work/streamtest"

speech() {  # speech <name> <rate> <text>
  say -r "$2" -o "$work/$1.aiff" "$3"
  afconvert -f WAVE -d LEF32@16000 -c 1 "$work/$1.aiff" "$work/$1.wav"
}
paragraph="I have been thinking about how we should plan the trip next month. The flights are cheaper on Tuesday, but the hotel only has rooms from Thursday onward, so we might need to stay with my cousin for two nights. Also, remember to renew your passport, because it expires in November and some countries require six months of validity. Let me know what you think, and we can book everything this weekend."
meeting="So the main thing I want to cover today is the migration plan for the billing service, which has been running on the old cluster for almost three years now. We need to move it before the end of the quarter because the hardware lease expires, and honestly the deployment process there is painful. My proposal is that we split the work into three phases. First we set up the new infrastructure and mirror the traffic without serving it. Then we switch reads over gradually while writes still go to the old database. Finally we cut over writes during a low traffic window on a weekend and keep the old system around as a fallback for two weeks."
speech normal 175 "$paragraph"
speech meeting 220 "$meeting"
speech long 190 "$paragraph $meeting $paragraph"
speech fast 260 "$paragraph"
speech short 175 "Quick note to self: buy milk."
speech after 175 "Okay, after that long pause, here is the rest of what I wanted to say about the budget for next quarter."
# A sentence, 8 seconds of faint room noise, then more speech.
.venv/bin/python -c "
import numpy as np, soundfile as sf
a, sr = sf.read('$work/short.wav', dtype='float32'); b, _ = sf.read('$work/after.wav', dtype='float32')
noise = np.random.default_rng(0).normal(0, 0.001, 8 * sr).astype('float32')
sf.write('$work/pause.wav', np.concatenate([a, noise, b]), sr, subtype='FLOAT')"

failed=0
for clip in normal fast meeting long short pause; do
  echo "== $clip"
  "$work/streamtest" "$work/$clip.wav" || failed=1
done
exit $failed
