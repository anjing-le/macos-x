# Computer Status / 电脑状态

The module keeps its `systemStatus` identity, saved enablement, CPU, memory,
network and startup-disk metrics. The temperature card directly shows common
components: CPU, GPU, and readable battery/storage/memory/board/cooling values.
There is no raw sensor list, per-core ID display, count or catalogue scan.

CPU/GPU keep the existing averages. Other component values use the hottest
readable confirmed point in that component, avoiding an average that conceals
one hotter battery or storage point. The tooltip states this policy. macOS
`ProcessInfo.thermalState` pressure remains a separate OS assessment; the app
infers no universal overheating threshold and controls no fans.

Unknown-location keys are neither queried nor promoted into component labels.
Only platform-specific known CPU/GPU keys and confirmed additional component
keys are read, capped at 128. Unsupported optional components are absent;
previously available components retain an unavailable placeholder on read
failure. Zero, negative, nonfinite and above-150-degree values are unavailable.
The cooling-region reading is not advertised as room or case temperature.

`SystemTemperatureReader.swift` isolates the undocumented AppleSMC protocol,
using IOKit read-bytes (5) and key-info (9) only. There is no key-by-index command,
full catalogue discovery, root, helper, subprocess, driver or third-party runtime.
Sessions are always closed before returning; cached key metadata is bounded by
the fixed monitored set. Source facts: [Stats sensor definitions](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift)
and [SMC layout research](https://github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md).

The existing serial sampler owns the four-second temperature cache and
thirty-second all-unavailable backoff. Stop/sleep cancels delivery generations;
wake recreates the reader. An in-flight synchronous driver call may finish, but
cannot publish into a stopped or newer session. No extra timer or observer.

The card holds at most seven component rows in one/two columns, with ordinary
native accessible labels and a small matching graphite/crayon component glyph.
The icons are decorative native paths, not extra accessibility stops, battery
charge indicators or animated fan controls. No new image assets or sensor reads. Layout adapts
the adjacent disk strip height without adding another panel or reading area.

`zsh tools/run-system-status-regression.sh` covers decoding, known-key selection,
aggregation, unknown-key exclusion, unavailable values, serial sampling,
stop/sleep/restart generations and Chinese/English wide/narrow offscreen UI.
`--live-sample` measures ten isolated read-only native samples; it does not drive
the installed app, desktop, preferences or clipboard. One machine's results are
not proof of all hardware compatibility.
