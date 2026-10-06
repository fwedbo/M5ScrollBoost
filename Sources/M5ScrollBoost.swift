import AppKit
import CoreGraphics
import IOKit.ps
import Metal
import SwiftUI

enum BoostMode: String, CaseIterable, Identifiable {
    case off
    case onScroll = "on_scroll"
    case continuous

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .onScroll: return "On scroll"
        case .continuous: return "Continuous"
        }
    }

    static func restored(from value: String?) -> BoostMode {
        if let value, let mode = Self(rawValue: value) { return mode }
        return allCases.first(where: { $0.label == value }) ?? .onScroll
    }
}

enum BoostStrength: String, CaseIterable, Identifiable {
    case gentle
    case balanced
    case strong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gentle: return "Gentle — experimental"
        case .balanced: return "Balanced"
        case .strong: return "Strong"
        }
    }

    static func restored(from value: String?) -> BoostStrength {
        if let value, let strength = Self(rawValue: value) { return strength }
        switch value {
        case "Gentle", "Gentle [blit 4B, 3-deep]": return .gentle
        case "Balanced", "Balanced [sin/cos 4K, 3-deep]": return .balanced
        case "Strong": return .strong
        default: return .balanced
        }
    }

    var threadCount: Int {
        switch self {
        case .gentle: return 4_096
        case .balanced: return 8_192
        case .strong: return 16_384
        }
    }

    var iterations: UInt32 {
        switch self {
        case .gentle: return 64
        case .balanced: return 128
        case .strong: return 256
        }
    }

    var queuedBufferCount: Int {
        switch self {
        case .gentle, .balanced, .strong: return 3
        }
    }

    /// Gentle submits a four-byte blit; Balanced and Strong use compute.
    /// All profiles retain three queued buffers with no sleep between
    /// submissions. Earlier compute-based Gentle measurements do not
    /// validate this experimental blit profile.
    var isBlit: Bool {
        switch self {
        case .gentle: return true
        case .balanced, .strong: return false
        }
    }
}

private struct DisplayInfo {
    let id: CGDirectDisplayID
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    var isTarget: Bool {
        guard CGDisplayIsBuiltin(id) == 0 else { return false }

        let isFiveK = pixelWidth >= 5_000 && pixelHeight >= 2_800
        let isHighRefresh = refreshRate >= 100
        let isStudioDisplayXDR = name.localizedCaseInsensitiveContains("Studio Display XDR")

        // Some adaptive modes report 0 Hz through CoreGraphics. Keep the exact
        // Studio Display XDR name as a fallback, while requiring 5K dimensions.
        return isFiveK && (isHighRefresh || (refreshRate == 0 && isStudioDisplayXDR))
    }

    var summary: String {
        let rate = refreshRate > 0 ? String(format: "%.0f Hz", refreshRate) : "adaptive rate"
        return "\(name): \(pixelWidth)×\(pixelHeight), \(rate)"
    }
}

private enum MetalBoostError: LocalizedError {
    case noDevice
    case noQueue
    case shaderCompilation(String)
    case noFunction
    case noBuffer

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "Metal is unavailable."
        case .noQueue:
            return "The Metal command queue could not be created."
        case .shaderCompilation(let message):
            return "The Metal shader could not be compiled: \(message)"
        case .noFunction:
            return "The Metal keep-alive function is missing."
        case .noBuffer:
            return "The Metal work buffer could not be allocated."
        }
    }
}

/// Keeps a few short command buffers queued instead of submitting one long
/// dispatch. The GPU can yield at command-buffer boundaries frequently, which
/// reduces the chance of blocking WindowServer for an entire 8.33 ms frame.
private final class MetalBoostEngine {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void dvfsKeepAlive(
        device float *values [[buffer(0)]],
        constant uint &iterations [[buffer(1)]],
        uint id [[thread_position_in_grid]])
    {
        float value = values[id];

        // A dependent recurrence prevents the compiler from removing the ALU
        // work. It intentionally mirrors the workload that improved the trace,
        // but each dispatch is much shorter.
        for (uint index = 0; index < iterations; ++index) {
            value = sin(value) * cos(value) + 0.001f;
        }

        values[id] = value;
    }
    """

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer
    private let worker = DispatchQueue(
        label: "com.fredb.M5ScrollBoost.metal",
        qos: .userInitiated
    )

    private var active = false
    private var generation: UInt64 = 0
    private var strength: BoostStrength = .balanced
    private var sampleTotalMilliseconds = 0.0
    private var sampleCount = 0
    private var sampleWindowStart = DispatchTime.now().uptimeNanoseconds
    private let telemetryIntervalNanoseconds: UInt64 = 750_000_000
    private var telemetryHandler: ((Double) -> Void)?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalBoostError.noDevice
        }
        guard let queue = device.makeCommandQueue(maxCommandBufferCount: 8) else {
            throw MetalBoostError.noQueue
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw MetalBoostError.shaderCompilation(error.localizedDescription)
        }

        guard let function = library.makeFunction(name: "dvfsKeepAlive") else {
            throw MetalBoostError.noFunction
        }

        self.commandQueue = queue
        self.pipeline = try device.makeComputePipelineState(function: function)

        let elementCount = BoostStrength.strong.threadCount
        let byteCount = elementCount * MemoryLayout<Float>.stride
        guard let workBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
            throw MetalBoostError.noBuffer
        }
        self.buffer = workBuffer

        let values = workBuffer.contents().bindMemory(to: Float.self, capacity: elementCount)
        for index in 0..<elementCount {
            values[index] = Float(index + 1) * 0.0001
        }
    }

    func setTelemetryHandler(_ handler: @escaping (Double) -> Void) {
        worker.async { [weak self] in
            self?.telemetryHandler = handler
        }
    }

    func start(strength requestedStrength: BoostStrength) {
        worker.async { [weak self] in
            guard let self else { return }
            let laneCountChanged = self.strength.queuedBufferCount != requestedStrength.queuedBufferCount
            self.strength = requestedStrength

            if self.active {
                if laneCountChanged {
                    self.restartSubmissionLanes()
                }
                return
            }

            self.active = true
            self.resetTelemetryWindow()
            self.generation &+= 1
            let token = self.generation

            for _ in 0..<requestedStrength.queuedBufferCount {
                self.submit(token: token)
            }
        }
    }

    func updateStrength(_ requestedStrength: BoostStrength) {
        worker.async { [weak self] in
            guard let self else { return }
            let laneCountChanged = self.strength.queuedBufferCount != requestedStrength.queuedBufferCount
            self.strength = requestedStrength
            self.resetTelemetryWindow()

            if self.active && laneCountChanged {
                self.restartSubmissionLanes()
            }
        }
    }

    func stop() {
        worker.async { [weak self] in
            guard let self, self.active else { return }
            self.active = false
            self.generation &+= 1
            self.resetTelemetryWindow()
        }
    }

    private func restartSubmissionLanes() {
        generation &+= 1
        let token = generation

        for _ in 0..<strength.queuedBufferCount {
            submit(token: token)
        }
    }

    private func resetTelemetryWindow() {
        sampleTotalMilliseconds = 0
        sampleCount = 0
        sampleWindowStart = DispatchTime.now().uptimeNanoseconds
    }

    private func submit(token: UInt64) {
        guard active, token == generation else { return }

        autoreleasepool {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }
            let currentStrength = strength

            if currentStrength.isBlit {
                guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
                    return
                }
                encoder.fill(buffer: buffer, range: 0..<4, value: 0)
                encoder.endEncoding()
            } else {
                guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                    return
                }

                var iterations = currentStrength.iterations

                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                encoder.setBytes(
                    &iterations,
                    length: MemoryLayout<UInt32>.stride,
                    index: 1
                )

                let grid = MTLSize(width: currentStrength.threadCount, height: 1, depth: 1)
                let groupWidth = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
                let group = MTLSize(width: groupWidth, height: 1, depth: 1)
                encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
                encoder.endEncoding()
            }

            commandBuffer.addCompletedHandler { [weak self] completedBuffer in
                guard let self else { return }
                let milliseconds = max(
                    0,
                    (completedBuffer.gpuEndTime - completedBuffer.gpuStartTime) * 1_000
                )

                self.worker.async { [weak self] in
                    self?.completed(token: token, milliseconds: milliseconds)
                }
            }

            commandBuffer.commit()
        }
    }

    private func completed(token: UInt64, milliseconds: Double) {
        guard active, token == generation else { return }

        if milliseconds > 0 {
            sampleTotalMilliseconds += milliseconds
            sampleCount += 1

            let now = DispatchTime.now().uptimeNanoseconds
            if now &- sampleWindowStart >= telemetryIntervalNanoseconds {
                let average = sampleTotalMilliseconds / Double(sampleCount)
                sampleTotalMilliseconds = 0
                sampleCount = 0
                sampleWindowStart = now
                telemetryHandler?(average)
            }
        }

        submit(token: token)
    }
}

final class BoostController: ObservableObject {
    static let appVersion = "v0.10"
    @Published var mode: BoostMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "boostMode")
            reevaluate()
        }
    }

    @Published var strength: BoostStrength {
        didSet {
            UserDefaults.standard.set(strength.rawValue, forKey: "boostStrength")
            engine?.updateStrength(strength)
        }
    }

    @Published private(set) var isBoosting = false
    @Published private(set) var statusText = "Starting…"
    @Published private(set) var displayText = "Checking displays…"
    @Published private(set) var timingText = ""

    private var engine: MetalBoostEngine?
    private var engineError: String?
    private var scrollMonitor: Any?
    private var stopBurstWorkItem: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var screensAreAwake = true
    private let burstTailSeconds = 0.9

    init() {
        let defaults = UserDefaults.standard
        self.mode = BoostMode.restored(from: defaults.string(forKey: "boostMode"))
        self.strength = BoostStrength.restored(from: defaults.string(forKey: "boostStrength"))
        defaults.set(mode.rawValue, forKey: "boostMode")
        defaults.set(strength.rawValue, forKey: "boostStrength")

        do {
            let createdEngine = try MetalBoostEngine()
            self.engine = createdEngine
            createdEngine.setTelemetryHandler { [weak self] milliseconds in
                DispatchQueue.main.async { [weak self] in
                    self?.timingText = String(format: "Metal batch: %.2f ms average", milliseconds)
                }
            }
        } catch {
            self.engineError = error.localizedDescription
        }

        installEventMonitor()
        installNotifications()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reevaluate(periodic: true)
        }
        reevaluate()
    }

    deinit {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        refreshTimer?.invalidate()
        stopBurstWorkItem?.cancel()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        engine?.stop()
    }

    func refreshNow() {
        reevaluate()
    }

    func openDisplaySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func quit() {
        engine?.stop()
        NSApplication.shared.terminate(nil)
    }

    private func installEventMonitor() {
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) > 0 else { return }
            self?.handleScroll(at: NSEvent.mouseLocation)
        }
    }

    private func installNotifications() {
        let thermalToken = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reevaluate()
        }
        notificationTokens.append(thermalToken)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let sleepToken = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screensAreAwake = false
            self?.stopBoost(status: "Paused while displays sleep")
        }
        notificationTokens.append(sleepToken)

        let wakeToken = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.screensAreAwake = true
            self?.reevaluate()
        }
        notificationTokens.append(wakeToken)
    }

    private func handleScroll(at point: NSPoint) {
        guard mode == .onScroll else { return }

        let displays = displayInfos()
        updateDisplayText(from: displays)

        guard canBoost(displays: displays) else { return }
        guard let pointerDisplay = display(at: point, from: displays), pointerDisplay.isTarget else {
            if !isBoosting {
                statusText = "Ready — scroll on the external 5K display"
            }
            return
        }

        startBoost(status: "Boosting while scrolling")
        stopBurstWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .onScroll else { return }
            self.stopBoost(status: "Ready — waiting for scrolling")
        }
        stopBurstWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + burstTailSeconds, execute: workItem)
    }

    private func reevaluate(periodic: Bool = false) {
        let displays = displayInfos()
        updateDisplayText(from: displays)

        if let engineError {
            stopBoost(status: engineError)
            return
        }

        if mode == .off {
            stopBurstWorkItem?.cancel()
            stopBoost(status: "Off")
            return
        }

        guard canBoost(displays: displays) else { return }

        switch mode {
        case .off:
            break
        case .onScroll:
            if !periodic {
                stopBurstWorkItem?.cancel()
                stopBoost(status: "Ready — waiting for scrolling")
            } else if !isBoosting {
                statusText = "Ready — waiting for scrolling"
            }
        case .continuous:
            startBoost(status: "Continuous boost active")
        }
    }

    private func canBoost(displays: [DisplayInfo]) -> Bool {
        guard engineError == nil, engine != nil else {
            stopBoost(status: engineError ?? "Metal is unavailable.")
            return false
        }

        guard screensAreAwake else {
            stopBoost(status: "Paused while displays sleep")
            return false
        }

        guard isUsingACPower() else {
            stopBoost(status: "Paused while running on battery")
            return false
        }

        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            stopBoost(status: "Paused because of thermal pressure")
            return false
        case .nominal, .fair:
            break
        @unknown default:
            stopBoost(status: "Paused because thermal state is unknown")
            return false
        }

        guard displays.contains(where: \.isTarget) else {
            stopBoost(status: "No external 5K high-refresh display detected")
            return false
        }

        return true
    }

    private func isUsingACPower() -> Bool {
        // Studio Display XDR normally supplies 140 W to the host. This public
        // IOKit call returns nil when no external adapter is connected.
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() != nil
    }

    private func startBoost(status: String) {
        guard engineError == nil, let engine else {
            stopBoost(status: engineError ?? "Metal is unavailable.")
            return
        }
        engine.start(strength: strength)
        isBoosting = true
        statusText = status
    }

    private func stopBoost(status: String) {
        engine?.stop()
        isBoosting = false
        statusText = status
        timingText = ""
    }

    private func displayInfos() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            guard let displayMode = CGDisplayCopyDisplayMode(displayID) else { return nil }

            return DisplayInfo(
                id: displayID,
                name: screen.localizedName,
                pixelWidth: displayMode.pixelWidth,
                pixelHeight: displayMode.pixelHeight,
                refreshRate: displayMode.refreshRate
            )
        }
    }

    private func display(at point: NSPoint, from infos: [DisplayInfo]) -> DisplayInfo? {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        let id = CGDirectDisplayID(number.uint32Value)
        return infos.first(where: { $0.id == id })
    }

    private func updateDisplayText(from displays: [DisplayInfo]) {
        if let target = displays.first(where: \.isTarget) {
            displayText = target.summary
        } else {
            displayText = "No external 5K 100+ Hz display detected"
        }
    }
}

private struct BoostMenu: View {
    @ObservedObject var controller: BoostController

    var body: some View {
        Text("M5 Scroll Boost \(BoostController.appVersion)").font(.caption).foregroundStyle(.secondary)
        Text(controller.displayText)
        Text(controller.statusText)
        if !controller.timingText.isEmpty {
            Text(controller.timingText)
        }

        Divider()

        Picker("Mode", selection: $controller.mode) {
            ForEach(BoostMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }

        Picker("Strength", selection: $controller.strength) {
            ForEach(BoostStrength.allCases) { strength in
                Text(strength.label).tag(strength)
            }
        }

        Divider()

        Button("Open Display Settings…") {
            controller.openDisplaySettings()
        }

        Button("Check Displays Again") {
            controller.refreshNow()
        }

        Divider()

        Button("Quit M5 Scroll Boost") {
            controller.quit()
        }
        .keyboardShortcut("q")
    }
}

@main
struct M5ScrollBoostApp: App {
    @StateObject private var controller = BoostController()

    var body: some Scene {
        MenuBarExtra {
            BoostMenu(controller: controller)
        } label: {
            Image(systemName: controller.isBoosting ? "bolt.fill" : "bolt")
        }
        .menuBarExtraStyle(.menu)
    }
}
