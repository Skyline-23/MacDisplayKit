---
evaluator:
  command: cd /Users/skyline23/code/Lumen && python3.12 tools/autoresearch/eval_host_stream.py --workspace src/platform/macos/Lumen.xcworkspace --scheme LumenTuistTests --log "/Users/skyline23/Library/Application Support/Lumen/lumen.log" --target-width 3512 --target-height 2290 --target-fps 120 --codec-suite hevc,prores-proxy --require-partial-hdr --require-low-latency --battery-policy adaptive-hdr
  format: env
  keep_policy: score_improvement
---
