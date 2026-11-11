import AppKit
import ApplicationServices

// Pixel-unit input is repeatable; Chrome's resulting CSS distance is not guaranteed.
struct ReplayPlan {
    static let rate = 120.0
    let speed: Double
    let duration: Double
    let direction: Int32
    var count: Int { Int((duration * Self.rate).rounded()) }
    func delta(at index: Int) -> Int32 {
        let before = (Double(index) * speed / Self.rate).rounded()
        let after = (Double(index + 1) * speed / Self.rate).rounded()
        return direction * Int32(after - before)
    }
}

private let escapeCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let app = Unmanaged<ReplayApp>.fromOpaque(context).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        app.stop("Cancelled: keyboard monitoring was interrupted.")
    } else if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 {
        app.stop("Cancelled with Escape.")
    }
    return Unmanaged.passUnretained(event)
}

final class ReplayApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let speed = NSTextField(string: "1200")
    private let duration = NSTextField(string: "10")
    private let countdown = NSTextField(string: "5")
    private let direction = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "Ready. Reset the page to the same position before every take.")
    private var startButton: NSButton!
    private var timer: DispatchSourceTimer?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var plan: ReplayPlan?
    private var origin = CGPoint.zero
    private var targetPID: pid_t = 0
    private var deadline: UInt64 = 0
    private var nextIndex = 0
    private var maxLate = 0.0
    private var lateCount = 0
    private var lastCountdown = -1
    private var running = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem()
        menu.addItem(item)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Scroll Replay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Scroll Replay"
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        let intro = NSTextField(wrappingLabelWithString: "Repeatable native scroll input for Chrome. During the countdown, focus Chrome and place the pointer over its page on the test display.")
        stack.addArrangedSubview(intro)
        for (label, field) in [("Speed (pixel-units / second)", speed), ("Duration (seconds)", duration), ("Countdown (seconds)", countdown)] {
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let row = NSStackView(views: [NSTextField(labelWithString: label), field])
            row.spacing = 12
            stack.addArrangedSubview(row)
        }
        direction.addItems(withTitles: ["Down", "Up"])
        stack.addArrangedSubview(direction)
        let permissions = NSButton(title: "Enable permissions…", target: self, action: #selector(enablePermissions))
        startButton = NSButton(title: "Start countdown", target: self, action: #selector(start))
        let stopButton = NSButton(title: "Stop / Escape", target: self, action: #selector(cancel))
        let buttons = NSStackView(views: [permissions, startButton!, stopButton])
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(status)
        intro.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { stop("Stopped.") }

    @objc private func enablePermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
        status.stringValue = "Enable Scroll Replay in Privacy & Security → Accessibility and Input Monitoring. Quit and reopen if requested."
    }

    @objc private func start() {
        guard timer == nil else { return }
        guard let s = Double(speed.stringValue), s.isFinite, (120...6000).contains(s),
              let d = Double(duration.stringValue), d.isFinite, (1...60).contains(d),
              let c = Double(countdown.stringValue), c.isFinite, (3...30).contains(c) else {
            status.stringValue = "Use speed 120–6000, duration 1–60, countdown 3–30."
            return
        }
        guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            enablePermissions()
            return
        }
        // A working global Escape monitor is required before posting any input.
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                            options: .listenOnly, eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue,
                                            callback: escapeCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            status.stringValue = "Cannot monitor Escape. Check Input Monitoring permission, then reopen the helper."
            return
        }
        tap = newTap
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        plan = ReplayPlan(speed: s, duration: d, direction: direction.indexOfSelectedItem == 0 ? -1 : 1)
        nextIndex = 0
        maxLate = 0
        lateCount = 0
        lastCountdown = -1
        startButton.isEnabled = false
        [speed, duration, countdown].forEach { $0.isEnabled = false }
        direction.isEnabled = false
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(c * 1_000_000_000)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.countdownTick() }
        timer = t
        t.resume()
    }

    private func countdownTick() {
        let now = DispatchTime.now().uptimeNanoseconds
        if now < deadline {
            let seconds = Int(ceil(Double(deadline - now) / 1_000_000_000))
            if seconds != lastCountdown {
                status.stringValue = "Starting in \(seconds)… Focus Chrome; pointer over the page. Escape cancels."
                lastCountdown = seconds
            }
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier?.hasPrefix("com.google.Chrome") == true else {
            stop("Cancelled: Chrome must be the foreground app when the countdown ends.")
            return
        }
        targetPID = front.processIdentifier
        origin = CGEvent(source: nil)?.location ?? .zero
        running = true
        deadline = now
        status.stringValue = "Scrolling. Escape cancels. Keep Chrome focused and the pointer still."
        timer?.setEventHandler { [weak self] in self?.scrollTick() }
        timer?.schedule(deadline: .now() + 1 / ReplayPlan.rate, repeating: 1 / ReplayPlan.rate, leeway: .microseconds(200))
    }

    private func scrollTick() {
        guard let plan else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            stop("Cancelled: foreground application changed.")
            return
        }
        let pointer = CGEvent(source: nil)?.location ?? .zero
        guard hypot(pointer.x - origin.x, pointer.y - origin.y) <= 30 else {
            stop("Cancelled: pointer moved. Keep it over the same page during a take.")
            return
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - deadline) / 1_000_000_000
        let expected = Double(nextIndex + 1) / ReplayPlan.rate
        let lateness = max(0, elapsed - expected)
        maxLate = max(maxLate, lateness)
        if lateness > 0.050 {
            stop("Invalid take: input timer fell over 50 ms behind. Repeat this take.")
            return
        }
        if lateness > 1 / ReplayPlan.rate { lateCount += 1 }
        guard post(delta: plan.delta(at: nextIndex), phase: nextIndex == 0 ? .began : .changed) else {
            stop("Cancelled: could not create a scroll event.")
            return
        }
        nextIndex += 1
        if nextIndex == plan.count {
            stop(String(format: "Completed: %d events, %.2f s, %.0f pixel-units/s. Max input delay %.2f ms; %d delays >8.33 ms. These are input timings, not display FPS.",
                        nextIndex, Double(plan.count) / ReplayPlan.rate, plan.speed, maxLate * 1000, lateCount))
        }
    }

    @discardableResult private func post(delta: Int32, phase: CGScrollPhase) -> Bool {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: delta, wheel2: 0, wheel3: 0) else { return false }
        event.location = origin
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        event.post(tap: .cghidEventTap)
        return true
    }

    @objc private func cancel() { stop("Cancelled.") }

    func stop(_ message: String) {
        timer?.cancel()
        timer = nil
        if running && nextIndex > 0 { post(delta: 0, phase: .ended) }
        running = false
        if let tap { CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        startButton?.isEnabled = true
        [speed, duration, countdown].forEach { $0.isEnabled = true }
        direction.isEnabled = true
        status.stringValue = message
    }
}

@main
enum ScrollReplayMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            for s in [120.0, 601, 6000] {
                for d in [1.0, 1.234, 10, 60] {
                    for sign: Int32 in [-1, 1] {
                        let p = ReplayPlan(speed: s, duration: d, direction: sign)
                        let deltas = (0..<p.count).map { p.delta(at: $0) }
                        precondition(deltas.allSatisfy { $0 * sign > 0 })
                        precondition(deltas.reduce(0, +) == sign * Int32((Double(p.count) * s / ReplayPlan.rate).rounded()))
                        precondition(deltas == (0..<p.count).map { p.delta(at: $0) })
                    }
                }
            }
            print("PASS: replay distances, directions, fractional rounding, and deterministic sequences. No input posted.")
            return
        }
        let app = NSApplication.shared
        let delegate = ReplayApp()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
