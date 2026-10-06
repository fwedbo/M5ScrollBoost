# M5 Scroll Boost

Current version: **1.0 (experimental)**.

An experimental macOS menu-bar workaround for scrolling stutter on external
5K displays at high refresh rates. It submits repeated short Metal workloads
while scrolling. It does not directly set GPU
clocks or make permanent system changes.

This project grew out of testing an M5 Pro MacBook Pro with an Apple Studio
Display XDR at 5120 × 2880 and fixed 120 Hz. Improvement depends on the workload
and system; this is not a guaranteed fix or an Apple-supported utility.
The app does **not** check that the processor is an M5.

## Requirements

- Apple silicon Mac; macOS 26 or 27; the build script targets arm64 with macOS 26 as its minimum.
- Apple's Command Line Tools or Xcode with the Swift compiler.
- AC power and a qualifying external display: at least 5000 × 2800 pixels and
  a reported refresh rate of 100 Hz or more. Studio Display XDR also qualifies
  when CoreGraphics reports 0 Hz (unknown/adaptive). A reported 60 Hz does not
  qualify, even for that display name.

The deployment target is not a claim that performance has been tested on
every supported macOS version, Mac, or display. See the testing notes below.

## Build and run

From the repository folder on a Mac:

```bash
chmod +x build.command
./build.command
```

The script compiles an optimized native executable, creates the app bundle,
ad-hoc signs it, and opens `build/M5ScrollBoost.app`. It preserves
`-parse-as-library`, required by this Swift entry-point layout. To build
without launching the GPU workload:

```bash
./build.command --no-open
```

If the toolchain is missing, run `xcode-select --install`. If Xcode requires
license acceptance, review and accept it in Xcode or with
`sudo xcodebuild -license`. If Command Line Tools are installed alongside
Xcode, you can select them for this build without changing your system-wide
selection:

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools ./build.command --no-open
```

The app shows a bolt in the menu bar and has no Dock icon. You can copy the
app to `/Applications` and optionally add it in System Settings → General →
Login Items. It does not install itself or add a login item.

Local builds are ad-hoc signed, not Developer ID signed or notarized.
Redistributing that app does not provide the normal notarized macOS
distribution experience. Source builds are the initial distribution method.

## Controls

New installations default to **On scroll + Gentle**. Settings use stable
identifiers, and recognized settings from older versions are migrated. A
missing or unrecognized strength falls back to Gentle. A previously saved
Continuous mode selection migrates to On scroll, and Strong migrates to
Balanced. Existing Gentle and Balanced selections are preserved.

| Mode | Behavior |
| --- | --- |
| Off | No GPU work is submitted. |
| On scroll | Activates while scrolling with the pointer on a qualifying external display; stops 0.9 seconds after the last scroll event. |

| Strength | Current workload per buffer |
| --- | --- |
| Gentle — experimental | Four-byte Metal blit fill. |
| Balanced | 8,192 threads × 128 dependent sin/cos iterations. |

Both strengths retain three queued command buffers with no deliberate
sleep between submissions. Start with Gentle; try Balanced if scrolling
does not improve. Balanced adds compute work and may compete with the
foreground app.

The filled bolt indicates the controller has requested boosting. The menu
reports the average GPU execution time of completed batches, updated about
every 750 ms. This value is not display frame time, GPU frequency, total
utilization, or a power measurement.

The app pauses on battery, serious or critical thermal pressure, and display
sleep. It uses a global scroll-wheel monitor; it does not modify or record
scroll events. If On scroll does not trigger on your system, check the menu
status and confirm the pointer is on a qualifying external display.

## Limitations and testing

This submits real GPU commands and can increase power use and heat, including
with the small Gentle blit workload. Quit it before games, benchmarks, or
sustained GPU rendering. It has no administrator helper, daemon, kernel
extension, or permanent system modification. To uninstall, quit and delete
the app; its mode and strength remain in the app's normal UserDefaults.

Recorded testing of the Gentle blit workload used the following setup:

- M5 Pro MacBook Pro, reported as 18 CPU cores / 40 GPU cores / 48 GB memory.
  These are reported values, not a fresh hardware inventory or a general
  compatibility claim.
- Apple Studio Display XDR, 27-inch, 5120 × 2880, fixed 120 Hz, with an
  Apple-supplied Thunderbolt cable.
- macOS 26.6.2 and macOS 27 RC (the exact RC build was not recorded).
- Codex conversation scrolling in the recorded macOS 26.6.2 session. The
  macOS 27 RC foreground application and a reproducible test page were not
  recorded.

The Gentle blit workload was reported smooth and associated with elevated
GPU frequency on macOS 27. A subsequent macOS 26.6.2 session still stuttered
despite high reported GPU clocks; reboot restored smooth scrolling. Those
observations do not isolate an Apple-internal clock, scheduling, or compositor
mechanism. No matched presentation benchmark or quantitative incremental
power measurement is claimed for this release. Detection of 165 Hz displays
is supported by the eligibility rule but was not validated by the recorded
120 Hz tests.

For a useful comparison, keep the foreground app, scroll workload, display
mode, energy mode, and capture length identical. Compare Off with On scroll
at the selected strength in short repeated captures. Metal System Trace can
generate substantial command-buffer event volume; use short
recordings, for example three seconds. GPU frequency telemetry alone and CADisplayLink
callback jitter do not establish foreground frame presentation quality.

## Project layout

- `Sources/M5ScrollBoost.swift` — menu, display/power checks, and Metal engine.
- `Info.plist` — menu-bar app metadata, deployment target, and version.
- `Resources/` — app icon.
- `build.command` — local build and ad-hoc signing.
- `Tools/CADisplayLinkJitter.swift` — optional investigation utility; not part
  of the app build or a measurement of actual presented frames.

Raw traces, machine logs, local build products, and recoverable checkpoints
are excluded from the public source repository.
