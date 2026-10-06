// CADisplayLinkJitter.swift — standalone display-link callback jitter sampler.
//
// Why: `displayed-surfaces-interval` from --all-processes traces mixes every
// process's surfaces. This samples CADisplayLink callbacks in a tiny app.
// Callback timing does not measure Chrome's presented frames or isolate
// WindowServer, GPU, or compositor causality.
//
// Build (on the affected Mac):
//   swiftc -O CADisplayLinkJitter.swift -o CADisplayLinkJitter \
//     -framework AppKit -framework QuartzCore
// Run:
//   ./CADisplayLinkJitter            # 8s sample on the current display
//   ./CADisplayLinkJitter 12         # 12s sample
//
// Readout: mean/stddev of callback intervals, % over 12.5ms, worst 20.
// Compare Off vs M5ScrollBoost Gentle under the SAME scroll workload
// (e.g. steady two-finger scroll in Safari behind the 1px window).
//
// Keep the window on the external 5K 120Hz display. It is 1x1, borderless,
// and is intended to add little GPU work. Keep all other conditions matched;
// differences between runs do not by themselves identify a subsystem.
import AppKit
import QuartzCore

let seconds: Double = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 8.0

final class JitterDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var link: CADisplayLink?
    var stamps: [CFTimeInterval] = []
    var target: CFTimeInterval = seconds

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1, height: 1),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        link = NSScreen.main?.displayLink(target: self, selector: #selector(tick(_:)))
        if link == nil {
            // Fallback: display link from the window (also macOS API).
            link = window.displayLink(target: self, selector: #selector(tick(_:)))
        }
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link?.add(to: .main, forMode: .common)
    }

    @objc func tick(_ sender: CADisplayLink) {
        stamps.append(sender.timestamp)
        if sender.timestamp - stamps[0] >= target {
            link?.invalidate()
            report()
            NSApplication.shared.terminate(nil)
        }
    }

    func report() {
        let iv = zip(stamps, stamps.dropFirst()).map { ($1 - $0) * 1000.0 }
        guard !iv.isEmpty else { print("no samples"); return }
        let mean = iv.reduce(0, +) / Double(iv.count)
        let variance = iv.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(iv.count)
        let over = iv.filter { $0 > 12.5 }
        print("samples: \(iv.count)  mean: \(String(format: "%.3f", mean)) ms  " +
              "stdev: \(String(format: "%.3f", variance.squareRoot())) ms  " +
              "min: \(String(format: "%.3f", iv.min()!))  max: \(String(format: "%.3f", iv.max()!))")
        print(">12.5ms: \(over.count) (\(String(format: "%.2f", 100.0 * Double(over.count) / Double(iv.count)))%)")
        let worst = iv.sorted(by: >).prefix(20).map { String(format: "%.2f", $0) }
        print("worst20ms: \(worst.joined(separator: ", "))")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = JitterDelegate()
app.delegate = delegate
app.run()
