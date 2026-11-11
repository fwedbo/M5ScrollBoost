# Scroll Replay

A standalone macOS companion app for [M5ScrollBoost](https://github.com/fwedbo/M5ScrollBoost)
that repeats the same scroll-input sequence in Google Chrome. Use it to compare
scrolling with the boost off and on, or to record a repeatable demonstration.

Choose a speed, duration, and direction, then start the countdown. Focus Chrome
and place the pointer over the page. Scroll Replay sends native macOS scroll
events and stops automatically when the run finishes.

It works independently of your mouse or trackpad. M5ScrollBoost is optional;
Scroll Replay can also be used on its own.

## Build and run

You need a Mac, Google Chrome, and Apple's Command Line Tools or Xcode with the
Swift compiler. If needed, install the Command Line Tools with
`xcode-select --install`.

From the M5ScrollBoost repository root:

```bash
bash Tools/ScrollReplay/build.command
```

Alternatively, open `Tools/ScrollReplay/` in Finder and double-click
`build.command`.

The script builds, ad-hoc signs, and opens the app at:

```text
build/ScrollReplay/ScrollReplay.app
```

You can reopen that app for subsequent runs without rebuilding. Local builds
are not Developer ID signed or notarized. The build uses the local toolchain's
default architecture and deployment target; compatibility with older macOS
versions has not been established.

## Permissions

On first use, click **Enable permissions…** and enable **Scroll Replay** in
**System Settings → Privacy & Security** under:

- **Accessibility**, to send scroll input.
- **Input Monitoring**, to detect Escape while Chrome is in front.

Quit and reopen Scroll Replay if macOS requests it. The helper checks these
permissions and requires a working keyboard event monitor before starting.
The monitor is active during the countdown and replay to detect Escape;
keystrokes are not recorded or saved.

## Controls

| Control | Default | Allowed values |
| --- | --- | --- |
| Speed | 1,200 pixel-units/second | 120–6,000 |
| Duration | 10 seconds | 1–60 seconds |
| Countdown | 5 seconds | 3–30 seconds |
| Direction | Down | Down or Up |

Click **Start countdown**, switch to Chrome, and put the pointer over the
page before the countdown ends. Chrome must be the foreground app when scrolling
starts. Keep the pointer still and avoid manual scrolling during the replay.

The replay stops automatically after the selected duration. You can cancel
with **Escape**, the **Stop / Escape** button, or by closing the app.
It also cancels if you switch away from Chrome or move the pointer more than
30 screen points from its starting position during scrolling.

## Compare M5ScrollBoost off and on

1. Open the same page in Chrome for every take. A saved local copy helps keep
   the content fixed. Keep the Chrome window size, browser zoom, display mode,
   and power settings the same. For a 120 Hz comparison, use fixed **120 Hz**.
2. Scroll through the intended test section once and wait for its images to
   load. Choose a section long enough for the whole replay.
3. Select M5ScrollBoost **Off** and return Chrome to your starting position.
   **Command–Home** returns to the top of the page.
4. In Scroll Replay, choose your settings and click **Start countdown**.
   Focus Chrome and put the pointer over the document on the test display.
   Keep the helper window behind Chrome or on another display when filming.
5. Let the replay finish and check its completion summary.
6. Select M5ScrollBoost **On scroll + Gentle**, reset Chrome to exactly the
   same starting position, and repeat with identical replay settings. Keep the
   pointer on the qualifying external display so the boost can activate.
7. Repeat the **Off** take to check that the difference is reproducible.

For video, film the display with a stationary camera and use the same framing,
exposure, and capture frame rate for both takes. Keep a real-time version and,
if recording at 120 fps, a quarter-speed version can make judder easier to see.

## Build checks

From the repository root, build without opening the app and run its self-test:

```bash
bash Tools/ScrollReplay/build.command --no-open
build/ScrollReplay/ScrollReplay.app/Contents/MacOS/ScrollReplay --self-test
```

The self-test checks scroll-distance arithmetic, direction, fractional rounding,
and repeatable sequences. It posts no input and needs no privacy permissions.
