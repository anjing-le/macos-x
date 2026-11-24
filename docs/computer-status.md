# Computer Status / 电脑状态

The former System Status display name is now Computer Status. The `systemStatus`
module identity and saved enablement are unchanged. CPU, memory, network and
startup-volume capacity retain their existing behavior.

The compact temperature card reports CPU/GPU averages in Celsius from readable
sensors, and separately shows `ProcessInfo.thermalState` pressure. The average
is not case temperature, a single package sensor, or the hottest core. Missing,
zero, nonfinite, negative and above-150-degree readings are unavailable, never
fabricated as zero. No universal CPU warning threshold is inferred from degrees.

## Sensor boundary

`SystemTemperatureReader.swift` isolates the undocumented AppleSMC read protocol.
It calls IOKit directly, without Homebrew, Stats, root, shell commands, drivers,
privileged helpers, fan control or writes. Only key-info (9), key-by-index (8) and read-bytes (5)
commands are issued. Every session is closed before returning. The 80-byte ABI
uses explicit offsets and only recognized sp78 and little-endian flt formats.

Known M1–M5 CPU/GPU mappings are generation-specific. All readable temperature
keys are additionally discovered from the machine's actual SMC catalogue. Known
battery, storage, memory, board and cooling mappings get category labels; other
keys retain their raw identity without guessed location, including on unknown
hardware generations. Some SMC values are derived/overlapping telemetry rather
than a unique physical sensor; the list counts readings, not physical probes. Intel reads known CPU
and GPU diode/package keys. Not every supported Mac necessarily exposes these
sensors; this is graceful compatibility, not a claim of testing every model.
No sensors from another hardware generation are guessed. Mapping facts were
checked against [Stats sensor definitions](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift).
Protocol layout can be checked against [SMC protocol research](https://github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md).
The implementation is independent and does not embed the Stats runtime.

## Resource lifetime

The existing two-second serial sampler owns temperature reads, with a four-second
cache; fully unavailable readings back off for thirty seconds. Failed refreshes
clear old degree values. Catalogue discovery happens incrementally on existing
two-second ticks: up to 1,024 indices and a 30 ms between-call budget per step,
up to 8,192 catalogue indices and 1,024 retained temperature candidates. Completed
catalogues are not rescanned during the worker lifetime. Limits and discovery
failures are visible, not silently reported as a complete list. Only sp78/flt
readings in the valid range are displayed. Previously readable failed sensors
remain as unavailable rows instead of retaining stale temperatures. Discovery's
budget is cooperative, not a kernel-call timeout; reading the bounded candidate
list is serial. There is no retained connection, extra timer or idle subprocess.

The detailed list draws only rows intersecting its dirty region and retains two
native text fields total, plus bounded accessibility elements. No view per sensor
or new histories/charts are created; unchanged lists skip updates. Wide pages
use two columns, narrow pages one. Disabling clears list contents. Supported
categories are only shown when actually present; unknown raw keys stay visible.
Stop/sleep cancel the existing worker generation; an in-flight native call may
finish but cannot publish stale readings. Wake creates a fresh cache.

Use `zsh tools/run-system-status-regression.sh` for deterministic decoding,
throttling, missing-data, lifecycle and wide/narrow offscreen UI checks. Add
`--live-sample` for ten isolated read-only native samples and measured CPU/time.
English uses `MACOSX_TEST_LANGUAGE=en`. These checks do not operate the user's
installed app, desktop UI, clipboard or preferences. Native sample results on one
machine are not proof of all hardware compatibility.
