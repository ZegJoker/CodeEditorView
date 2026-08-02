# Performance budgets (§26.7)

Named budgets for reference Macs (Apple Silicon) and iOS simulators. Measured by editor harnesses / CI when available. Values are **initial** pre-alpha targets; regressions require reviewed baseline change.

| Metric | Platform | P50 budget | P95 budget | Notes |
|---|---|---|---|---|
| keystroke-to-present | macOS | 8 ms | 16 ms | Main-thread paint after edit |
| editor memory per 1 MB file | macOS | 32 MB | 48 MB | RSS + layout + highlights |
| first visible frame | macOS | 100 ms | 250 ms | After open document |
| scroll frame time | macOS | 8 ms | 16 ms | 60 Hz class |
| incremental parse time | macOS | 5 ms | 20 ms | Tree-sitter edit |
| workspace load/index | macOS | 500 ms | 2 s | 1k files sample |
| search throughput | macOS | 50 MB/s | 20 MB/s floor | Content search |
| LSP request overhead | macOS | 2 ms | 10 ms | Host framing only |
| task output throughput | macOS | 20 MB/s | 5 MB/s floor | Streaming matchers |
| terminal throughput/frame | macOS | 8 ms | 16 ms | Ghostty path |
| terminal memory | macOS | 64 MB | 128 MB | Session + surface |
| extension activation | macOS | 50 ms | 200 ms | Data-only package |
| host-call overhead | macOS | 0.5 ms | 2 ms | Broker single call |

## Regression policy

- CI `check-perf-budgets.sh` ensures this file documents all §26.7 topics (including first visible frame).
- `Phase11PerfSmokeTests` writes `Baselines/evidence/perf-smoke.json` with a measured unit-cost sample.
- Harness numbers (when present under `Baselines/evidence/perf-*.json`) must not exceed P95 without an ADR/baseline bump.

## Reference devices

- Mac: Apple Silicon, 16 GB RAM class  
- iOS: current simulator paired with Xcode pin  
