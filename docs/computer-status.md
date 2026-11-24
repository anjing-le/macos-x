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
privileged helpers, fan control or writes. Only key-info (9) and read-bytes (5)
commands are issued. Every session is closed before returning. The 80-byte ABI
uses explicit offsets and only recognized sp78 and little-endian flt formats.

Known M1–M5 CPU/GPU mappings are generation-specific; unknown generations expose
OS thermal pressure without claiming Celsius support. Intel reads known CPU
and GPU diode/package keys. Not every supported Mac necessarily exposes these
sensors; this is graceful compatibility, not a claim of testing every model.
No sensors from another hardware generation are guessed. Mapping facts were
checked against [Stats sensor definitions](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift).
Protocol layout can be checked against [SMC protocol research](https://github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md).
The implementation is independent and does not embed the Stats runtime.

## Resource lifetime

The existing two-second serial sampler owns temperature reads, with a four-second
cache; fully unavailable readings back off for thirty seconds. Failed refreshes
clear old degree values. At most 32 keys per group and 50 ms between-call budget
bound normal work. This is a cooperative budget, not a kernel-call timeout.
No full SMC enumeration, retained connection, extra timer or idle subprocess.
Stop/sleep cancel the existing worker generation; an in-flight native call may
finish but cannot publish stale readings. Wake creates a fresh cache.

Use `zsh tools/run-system-status-regression.sh` for deterministic decoding,
throttling, missing-data, lifecycle and wide/narrow offscreen UI checks. Add
`--live-sample` for ten isolated read-only native samples and measured CPU/time.
English uses `MACOSX_TEST_LANGUAGE=en`. These checks do not operate the user's
installed app, desktop UI, clipboard or preferences. Native sample results on one
machine are not proof of all hardware compatibility.
