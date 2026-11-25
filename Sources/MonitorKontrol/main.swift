import AppKit
@preconcurrency import ApplicationServices
import Darwin
import Foundation
import SwiftUI

struct NumericCapability: Sendable, Equatable {
    var current: Int
    let maximum: Int
}

enum DisplayKind: Sendable, Equatable {
    case builtIn
    case external
}

struct DisplayDevice: Identifiable, Sendable, Equatable {
    let id: String
    let index: Int
    let name: String
    let kind: DisplayKind
    var brightness: NumericCapability?
    var contrast: NumericCapability?
    var volume: NumericCapability?
    var mute: Int?
    var writeOnlyFallback: Bool
}

struct CommandResult: Sendable {
    let status: Int32
    let output: String
    var succeeded: Bool { status == 0 }
}

private enum MediaKeyAction: Sendable {
    case volumeUp
    case volumeDown
    case toggleMute
}

private final class MediaKeyController {
    private static let systemDefinedEventType = CGEventType(rawValue: 14)!
    private let handler: @MainActor @Sendable (MediaKeyAction) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var isRunning: Bool { eventTap != nil }

    init(handler: @escaping @MainActor @Sendable (MediaKeyAction) -> Void) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start(promptForPermission: Bool) -> Bool {
        if isRunning { return true }

        guard Self.accessibilityIsTrusted(prompt: promptForPermission) else { return false }

        let eventMask = CGEventMask(1) << Self.systemDefinedEventType.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<MediaKeyController>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                return controller.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    static func accessibilityIsTrusted(prompt: Bool) -> Bool {
        guard prompt else { return AXIsProcessTrusted() }
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == Self.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let data = nsEvent.data1
        let keyCode = (data & 0xFFFF0000) >> 16
        let keyState = (data & 0x0000FF00) >> 8
        let action: MediaKeyAction

        switch keyCode {
        case 0: action = .volumeUp
        case 1: action = .volumeDown
        case 7: action = .toggleMute
        default: return Unmanaged.passUnretained(event)
        }

        // 0xA is key-down (including repeats), 0xB is key-up. Consume both so
        // macOS does not also show the locked HDMI volume indicator.
        if keyState == 0xA {
            DispatchQueue.main.async { [handler] in handler(action) }
        }
        return nil
    }
}

actor DDCClient {
    private let helperURL: URL

    init() {
        if let customPath = ProcessInfo.processInfo.environment["MONITORKONTROL_HELPER"] {
            helperURL = URL(fileURLWithPath: customPath)
        } else if let bundled = Bundle.main.url(forResource: "m1ddc", withExtension: nil) {
            helperURL = bundled
        } else {
            helperURL = URL(fileURLWithPath: "/usr/local/bin/m1ddc")
        }
    }

    func discover(probeControls: Bool) -> ([DisplayDevice], String?) {
        let result = run(["display", "list", "detailed"])
        guard result.succeeded else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty || message.contains("No external display found") {
                return ([], nil)
            }
            return ([], message)
        }

        let expression = try? NSRegularExpression(pattern: #"^\[(\d+)\]\s+(.+)\s+\(([^)]+)\)$"#)
        let lines = result.output.split(whereSeparator: \.isNewline).map(String.init)
        var devices: [DisplayDevice] = []

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = expression?.firstMatch(in: line, range: range), match.numberOfRanges == 4,
                  let indexRange = Range(match.range(at: 1), in: line),
                  let nameRange = Range(match.range(at: 2), in: line),
                  let idRange = Range(match.range(at: 3), in: line),
                  let index = Int(line[indexRange]) else { continue }

            let rawName = String(line[nameRange])
            let displayName = rawName == "Unknown Display" ? "Harici Monitör" : rawName
            let brightness = probeControls ? probeNumeric(index: index, command: "luminance") : nil
            let contrast = probeControls ? probeNumeric(index: index, command: "contrast") : nil
            let volume = probeControls ? probeNumeric(index: index, command: "volume") : nil
            let mute = probeControls ? probeValue(index: index, command: "mute") : nil
            let needsWriteOnlyFallback = brightness == nil || contrast == nil || volume == nil ||
                mute == nil

            devices.append(DisplayDevice(
                id: String(line[idRange]),
                index: index,
                name: displayName,
                kind: .external,
                brightness: brightness ?? (needsWriteOnlyFallback ? NumericCapability(current: 50, maximum: 100) : nil),
                contrast: contrast ?? (needsWriteOnlyFallback ? NumericCapability(current: 50, maximum: 100) : nil),
                volume: volume ?? (needsWriteOnlyFallback ? NumericCapability(current: 50, maximum: 100) : nil),
                mute: mute ?? (needsWriteOnlyFallback ? 2 : nil),
                writeOnlyFallback: needsWriteOnlyFallback
            ))
        }
        return (devices, nil)
    }

    func set(index: Int, command: String, value: Int) -> CommandResult {
        run(["display", String(index), "set", command, String(value)])
    }

    private func probeNumeric(index: Int, command: String) -> NumericCapability? {
        guard let current = probeValue(index: index, command: command) else { return nil }
        let maxResult = run(["display", String(index), "max", command])
        let maximum = parseInteger(maxResult.output) ?? 100
        return NumericCapability(current: current, maximum: max(maximum, 1))
    }

    private func probeValue(index: Int, command: String) -> Int? {
        let result = run(["display", String(index), "get", command])
        guard result.succeeded else { return nil }
        return parseInteger(result.output)
    }

    private func parseInteger(_ text: String) -> Int? {
        text.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Int($0) }.first
    }

    private func run(_ arguments: [String]) -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return CommandResult(status: 127, output: "m1ddc bulunamadı: \(helperURL.path)")
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = helperURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(
                status: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return CommandResult(status: 126, output: error.localizedDescription)
        }
    }
}

private typealias DisplayServicesGetBrightness = @convention(c) (
    CGDirectDisplayID,
    UnsafeMutablePointer<Float>
) -> Int32
private typealias DisplayServicesSetBrightness = @convention(c) (
    CGDirectDisplayID,
    Float
) -> Int32

final class BuiltInDisplayController {
    private let frameworkHandle: UnsafeMutableRawPointer?
    private let getBrightness: DisplayServicesGetBrightness?
    private let setBrightness: DisplayServicesSetBrightness?

    init() {
        frameworkHandle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        )
        if let frameworkHandle,
           let getSymbol = dlsym(frameworkHandle, "DisplayServicesGetBrightness"),
           let setSymbol = dlsym(frameworkHandle, "DisplayServicesSetBrightness") {
            getBrightness = unsafeBitCast(getSymbol, to: DisplayServicesGetBrightness.self)
            setBrightness = unsafeBitCast(setSymbol, to: DisplayServicesSetBrightness.self)
        } else {
            getBrightness = nil
            setBrightness = nil
        }
    }

    func discover() -> DisplayDevice? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displayIDs = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetOnlineDisplayList(count, &displayIDs, &count) == .success,
              let displayID = displayIDs.first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }

        var rawBrightness: Float = 0.5
        if getBrightness?(displayID, &rawBrightness) != 0 {
            rawBrightness = 0.5
        }
        let percent = Int((min(max(rawBrightness, 0), 1) * 100).rounded())

        return DisplayDevice(
            id: "builtin-\(displayID)",
            index: Int(displayID),
            name: "MacBook Pro Ekranı",
            kind: .builtIn,
            brightness: NumericCapability(current: percent, maximum: 100),
            contrast: nil,
            volume: nil,
            mute: nil,
            writeOnlyFallback: false
        )
    }

    func setBrightness(displayID: Int, percent: Int) -> Bool {
        guard let setBrightness else { return false }
        let normalized = Float(min(max(percent, 0), 100)) / 100
        return setBrightness(CGDirectDisplayID(displayID), normalized) == 0
    }

    deinit {
        if let frameworkHandle { dlclose(frameworkHandle) }
    }
}

private let relevantDisplayChangeMask: UInt32 =
    (1 << 4) |  // Ekran eklendi
    (1 << 5) |  // Ekran kaldırıldı
    (1 << 8) |  // Ekran etkinleştirildi
    (1 << 9)    // Ekran devre dışı bırakıldı

private func displayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard flags.rawValue & relevantDisplayChangeMask != 0, let userInfo else { return }
    let observer = Unmanaged<DisplayChangeObserver>.fromOpaque(userInfo).takeUnretainedValue()
    observer.scheduleRefresh()
}

final class DisplayChangeObserver {
    private let onChange: () -> Void
    private var firstRefresh: DispatchWorkItem?
    private var followUpRefresh: DispatchWorkItem?
    private var notificationTokens: [NSObjectProtocol] = []
    private var isStarted = false

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        CGDisplayRegisterReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationTokens = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.scheduleRefresh() },
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.scheduleRefresh() }
        ]
    }

    func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            firstRefresh?.cancel()
            followUpRefresh?.cancel()

            let first = DispatchWorkItem { [weak self] in self?.onChange() }
            let followUp = DispatchWorkItem { [weak self] in self?.onChange() }
            firstRefresh = first
            followUpRefresh = followUp

            // HDMI el sıkışması ve EDID/DDC servislerinin oluşması biraz gecikebilir.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: first)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: followUp)
        }
    }

    deinit {
        firstRefresh?.cancel()
        followUpRefresh?.cancel()
        if isStarted {
            CGDisplayRemoveReconfigurationCallback(
                displayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notificationTokens.forEach(workspaceCenter.removeObserver)
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var displays: [DisplayDevice] = []
    @Published var status = "Monitörler aranıyor…"
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published private(set) var mediaKeyTargetDisplayID: String?
    @Published private(set) var mediaKeyPermissionRequired = false

    private let client = DDCClient()
    private let builtInController = BuiltInDisplayController()
    private var displayObserver: DisplayChangeObserver?
    private var mediaKeyController: MediaKeyController?
    private var mediaKeyVolumeWriteTasks: [String: Task<Void, Never>] = [:]
    private var mediaKeyVolumeGenerations: [String: Int] = [:]
    private var confirmedMediaKeyVolumes: [String: Int] = [:]
    private var lastAudibleVolumes: [String: Int] = [:]
    private var pendingMediaKeyUnmuteDisplayIDs: Set<String> = []
    private var hasStarted = false
    private static let mediaKeyTargetDefaultsKey = "mediaKeyTargetDisplayID"
    private static let mediaKeyVolumeStep = 5

    init() {
        mediaKeyTargetDisplayID = UserDefaults.standard.string(
            forKey: Self.mediaKeyTargetDefaultsKey
        )
        mediaKeyController = MediaKeyController { [weak self] action in
            self?.handleMediaKey(action)
        }
        displayObserver = DisplayChangeObserver { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // Win the startup race with display callbacks: the first refresh must probe
        // the monitor instead of populating the UI with write-only fallback values.
        refresh(probeControls: true)
        displayObserver?.start()
    }

    func refresh(probeControls: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = nil
        status = "Monitörler aranıyor…"

        Task {
            let builtIn = builtInController.discover()
            let (discoveredExternalDisplays, error) = await client.discover(probeControls: probeControls)
            let externalDisplays = probeControls
                ? discoveredExternalDisplays
                : preserveKnownControls(in: discoveredExternalDisplays)
            displays = [builtIn].compactMap { $0 } + externalDisplays
            for display in externalDisplays {
                if probeControls || confirmedMediaKeyVolumes[display.id] == nil,
                   let currentVolume = display.volume?.current {
                    confirmedMediaKeyVolumes[display.id] = currentVolume
                }
                if let currentVolume = display.volume?.current, currentVolume > 0 {
                    lastAudibleVolumes[display.id] = currentVolume
                }
            }
            isRefreshing = false
            lastError = error
            if externalDisplays.isEmpty, builtIn != nil {
                status = "Dahili ekran hazır"
            } else if externalDisplays.isEmpty {
                status = "Ekran bulunamadı"
            } else {
                status = "\(externalDisplays.count) harici monitör bulundu"
            }
            synchronizeMediaKeyCapture()
        }
    }

    private func preserveKnownControls(in discovered: [DisplayDevice]) -> [DisplayDevice] {
        let previousByID = Dictionary(
            uniqueKeysWithValues: displays
                .filter { $0.kind == .external }
                .map { ($0.id, $0) }
        )

        return discovered.map { fresh in
            guard let previous = previousByID[fresh.id] else { return fresh }
            return DisplayDevice(
                id: fresh.id,
                index: fresh.index,
                name: fresh.name,
                kind: fresh.kind,
                brightness: previous.brightness,
                contrast: previous.contrast,
                volume: previous.volume,
                mute: previous.mute,
                writeOnlyFallback: previous.writeOnlyFallback
            )
        }
    }

    func set(_ command: String, value: Int, on display: DisplayDevice) {
        if display.kind == .builtIn {
            guard command == "luminance",
                  builtInController.setBrightness(displayID: display.index, percent: value) else {
                lastError = "Dahili ekran parlaklığı ayarlanamadı."
                return
            }
            update(displayID: display.id, command: command, value: value)
            lastError = nil
            return
        }

        Task {
            let result = await client.set(index: display.index, command: command, value: value)
            guard result.succeeded else {
                lastError = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            update(displayID: display.id, command: command, value: value)
            if command == "volume", value > 0 {
                lastAudibleVolumes[display.id] = value
            }
            lastError = nil
        }
    }

    func setLinkedBrightness(_ value: Int, contrastPercentage: Int, on display: DisplayDevice) {
        guard display.kind == .external,
              let brightness = display.brightness,
              let contrast = display.contrast else {
            set("luminance", value: value, on: display)
            return
        }

        let brightnessValue = min(max(value, 0), brightness.maximum)
        let contrastRatio = Double(min(max(contrastPercentage, 0), 100)) / 100
        let brightnessRatio = Double(brightnessValue) / Double(brightness.maximum)
        let contrastValue = min(
            max(Int((brightnessRatio * Double(contrast.maximum) * contrastRatio).rounded()), 0),
            contrast.maximum
        )

        Task {
            let brightnessResult = await client.set(
                index: display.index,
                command: "luminance",
                value: brightnessValue
            )
            guard brightnessResult.succeeded else {
                lastError = brightnessResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            update(displayID: display.id, command: "luminance", value: brightnessValue)

            guard contrastValue != contrast.current else {
                lastError = nil
                return
            }

            let contrastResult = await client.set(
                index: display.index,
                command: "contrast",
                value: contrastValue
            )
            guard contrastResult.succeeded else {
                let message = contrastResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                lastError = "Parlaklık ayarlandı; kontrast ayarlanamadı. \(message)"
                return
            }
            update(displayID: display.id, command: "contrast", value: contrastValue)
            lastError = nil
        }
    }

    func synchronizeLinkedContrast(percentage: Int, on display: DisplayDevice) {
        guard let brightness = display.brightness else { return }
        setLinkedBrightness(
            brightness.current,
            contrastPercentage: percentage,
            on: display
        )
    }

    func setMediaKeyTarget(_ enabled: Bool, displayID: String) {
        if enabled {
            if let previousTargetID = mediaKeyTargetDisplayID, previousTargetID != displayID {
                cancelPendingMediaKeyVolumeWrite(for: previousTargetID)
            }
            mediaKeyTargetDisplayID = displayID
            UserDefaults.standard.set(displayID, forKey: Self.mediaKeyTargetDefaultsKey)
            synchronizeMediaKeyCapture(promptForPermission: true)
        } else if mediaKeyTargetDisplayID == displayID {
            mediaKeyTargetDisplayID = nil
            UserDefaults.standard.removeObject(forKey: Self.mediaKeyTargetDefaultsKey)
            mediaKeyController?.stop()
            cancelPendingMediaKeyVolumeWrite(for: displayID)
            mediaKeyPermissionRequired = false
        }
    }

    func retryMediaKeyCapture() {
        guard mediaKeyTargetDisplayID != nil else { return }
        synchronizeMediaKeyCapture()
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func synchronizeMediaKeyCapture(promptForPermission: Bool = false) {
        guard let targetID = mediaKeyTargetDisplayID,
              displays.contains(where: {
                  $0.id == targetID && $0.kind == .external && $0.volume != nil
              }) else {
            mediaKeyController?.stop()
            if let targetID = mediaKeyTargetDisplayID {
                cancelPendingMediaKeyVolumeWrite(for: targetID)
            }
            mediaKeyPermissionRequired = false
            return
        }

        guard let mediaKeyController else { return }
        let started = mediaKeyController.start(promptForPermission: promptForPermission)
        mediaKeyPermissionRequired = !started && !MediaKeyController.accessibilityIsTrusted(prompt: false)
        if !started, !mediaKeyPermissionRequired {
            lastError = "Klavye medya tuşları dinlenemedi. MonitorKontrol'ü yeniden başlatmayı deneyin."
        }
    }

    private func handleMediaKey(_ action: MediaKeyAction) {
        guard let targetID = mediaKeyTargetDisplayID,
              let display = displays.first(where: { $0.id == targetID }) else {
            synchronizeMediaKeyCapture()
            return
        }

        switch action {
        case .volumeUp:
            adjustMediaKeyVolume(by: Self.mediaKeyVolumeStep, on: display)
        case .volumeDown:
            adjustMediaKeyVolume(by: -Self.mediaKeyVolumeStep, on: display)
        case .toggleMute:
            toggleAudioMute(on: display)
        }
    }

    func toggleAudioMute(on display: DisplayDevice) {
        guard display.kind == .external, let volume = display.volume else {
            if let mute = display.mute {
                set("mute", value: mute == 1 ? 2 : 1, on: display)
            }
            return
        }

        if volume.current == 0 {
            let fallbackVolume = min(max(20, 1), volume.maximum)
            let restoreVolume = min(
                max(lastAudibleVolumes[display.id] ?? fallbackVolume, 1),
                volume.maximum
            )
            set("volume", value: restoreVolume, on: display)
        } else {
            lastAudibleVolumes[display.id] = volume.current
            set("volume", value: 0, on: display)
        }
    }

    private func adjustMediaKeyVolume(by delta: Int, on display: DisplayDevice) {
        guard let volume = display.volume else { return }
        let newValue = min(max(volume.current + delta, 0), volume.maximum)
        guard newValue != volume.current else { return }

        let wasMuted = display.mute == 1
        update(displayID: display.id, command: "volume", value: newValue)
        if wasMuted {
            update(displayID: display.id, command: "mute", value: 2)
            pendingMediaKeyUnmuteDisplayIDs.insert(display.id)
        }

        mediaKeyVolumeWriteTasks[display.id]?.cancel()
        let generation = (mediaKeyVolumeGenerations[display.id] ?? 0) + 1
        mediaKeyVolumeGenerations[display.id] = generation
        mediaKeyVolumeWriteTasks[display.id] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 75_000_000)
            } catch {
                return
            }
            guard let self, self.mediaKeyVolumeGenerations[display.id] == generation else { return }
            await self.commitMediaKeyVolume(
                displayID: display.id,
                displayIndex: display.index,
                generation: generation
            )
        }
    }

    private func commitMediaKeyVolume(
        displayID: String,
        displayIndex: Int,
        generation: Int
    ) async {
        guard mediaKeyVolumeGenerations[displayID] == generation,
              let targetVolume = displays.first(where: { $0.id == displayID })?.volume?.current else {
            return
        }

        var errors: [String] = []
        if pendingMediaKeyUnmuteDisplayIDs.remove(displayID) != nil {
            let unmuteResult = await client.set(index: displayIndex, command: "mute", value: 2)
            if !unmuteResult.succeeded {
                errors.append(unmuteResult.output.trimmingCharacters(in: .whitespacesAndNewlines))
                if mediaKeyVolumeGenerations[displayID] == generation {
                    update(displayID: displayID, command: "mute", value: 1)
                }
            }
        }

        let result = await client.set(index: displayIndex, command: "volume", value: targetVolume)
        if result.succeeded {
            confirmedMediaKeyVolumes[displayID] = targetVolume
            if targetVolume > 0 {
                lastAudibleVolumes[displayID] = targetVolume
            }
        } else {
            errors.append(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            if mediaKeyVolumeGenerations[displayID] == generation,
               let confirmedVolume = confirmedMediaKeyVolumes[displayID] {
                update(displayID: displayID, command: "volume", value: confirmedVolume)
            }
        }

        if mediaKeyVolumeGenerations[displayID] == generation {
            mediaKeyVolumeWriteTasks[displayID] = nil
            lastError = errors.isEmpty ? nil : errors.filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private func cancelPendingMediaKeyVolumeWrite(for displayID: String) {
        mediaKeyVolumeWriteTasks[displayID]?.cancel()
        mediaKeyVolumeWriteTasks[displayID] = nil
        mediaKeyVolumeGenerations[displayID] = (mediaKeyVolumeGenerations[displayID] ?? 0) + 1
        pendingMediaKeyUnmuteDisplayIDs.remove(displayID)
    }

    private func update(displayID: String, command: String, value: Int) {
        guard let position = displays.firstIndex(where: { $0.id == displayID }) else { return }
        switch command {
        case "luminance": displays[position].brightness?.current = value
        case "contrast": displays[position].contrast?.current = value
        case "volume": displays[position].volume?.current = value
        case "mute": displays[position].mute = value
        default: break
        }
    }
}

struct ControlSlider: View {
    let title: String
    let icon: String
    let capability: NumericCapability
    let onCommit: (Int) -> Void
    var isMuted: Bool = false
    var onToggleMute: (() -> Void)?
    @State private var value: Double

    init(
        title: String,
        icon: String,
        capability: NumericCapability,
        isMuted: Bool = false,
        onToggleMute: (() -> Void)? = nil,
        onCommit: @escaping (Int) -> Void
    ) {
        self.title = title
        self.icon = icon
        self.capability = capability
        self.isMuted = isMuted
        self.onToggleMute = onToggleMute
        self.onCommit = onCommit
        _value = State(initialValue: Double(capability.current))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if let onToggleMute {
                    Button(action: onToggleMute) {
                        Image(systemName: isMuted ? "speaker.slash.fill" : icon)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help(isMuted ? "Sesi aç" : "Sessize al")
                    Text(title)
                } else {
                    Label(title, systemImage: icon)
                }
                Spacer()
                Text("\(Int(value))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $value,
                in: 0...Double(capability.maximum),
                step: 1,
                onEditingChanged: { editing in
                    if !editing { onCommit(Int(value)) }
                }
            )
            .disabled(isMuted)
        }
        .onChange(of: capability.current) { _, newValue in value = Double(newValue) }
    }
}

struct MonitorPanel: View {
    @EnvironmentObject private var model: MonitorModel
    @State private var expandedDisplayIDs: Set<String> = []
    @State private var knownDisplayIDs: Set<String> = []
    @State private var linkedContrastDisplayIDs: Set<String> = []
    @State private var linkedContrastPercentages: [String: Int] = [:]

    private static let percentageFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximum = 100
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let contrastEffectPresets = [25, 50, 75, 100]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MonitorKontrol").font(.headline)
                        Text(model.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.refresh(probeControls: true) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(model.isRefreshing)
                    .help("Monitörleri ve DDC değerlerini yeniden tara")
                }

                ForEach(model.displays) { display in
                    Divider()
                    DisclosureGroup(isExpanded: expansionBinding(for: display)) {
                        displayControls(for: display)
                            .padding(.top, 10)
                    } label: {
                        Label(
                            display.name,
                            systemImage: display.kind == .builtIn ? "laptopcomputer" : "display"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                }

                if model.displays.isEmpty {
                    ContentUnavailableView(
                        "Ekran bulunamadı",
                        systemImage: "display.trianglebadge.exclamationmark"
                    )
                    .frame(minHeight: 100)
                } else {
                    Text("Harici monitör bağlanınca HDMI kontrolleri otomatik eklenir.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let error = model.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }

                Divider()
                HStack {
                    Text("Yalnızca desteklenen kontroller gösterilir.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Çık") { NSApp.terminate(nil) }
                        .buttonStyle(.borderless)
                }
            }
            .padding(16)
        }
        .frame(width: 360)
        .frame(maxHeight: 600)
        .onAppear { synchronizeExpansionState() }
        .onChange(of: model.displays.map(\.id)) { _, _ in synchronizeExpansionState() }
    }

    private func expansionBinding(for display: DisplayDevice) -> Binding<Bool> {
        Binding(
            get: { expandedDisplayIDs.contains(display.id) },
            set: { isExpanded in
                if isExpanded {
                    expandedDisplayIDs.insert(display.id)
                } else {
                    expandedDisplayIDs.remove(display.id)
                }
            }
        )
    }

    private func synchronizeExpansionState() {
        let currentIDs = Set(model.displays.map(\.id))
        expandedDisplayIDs.formIntersection(currentIDs)
        knownDisplayIDs.formIntersection(currentIDs)
        linkedContrastDisplayIDs.formIntersection(currentIDs)
        linkedContrastPercentages = linkedContrastPercentages.filter { currentIDs.contains($0.key) }

        for display in model.displays where !knownDisplayIDs.contains(display.id) {
            if display.kind == .external {
                expandedDisplayIDs.insert(display.id)
            }
        }
        knownDisplayIDs = currentIDs
    }

    @ViewBuilder
    private func displayControls(for display: DisplayDevice) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if display.writeOnlyFallback {
                Label {
                    Text("HDMI uyumluluk modu: bazı değerler okunamıyor; değişiklikler doğrudan gönderilecek.")
                } icon: {
                    Image(systemName: "cable.connector.horizontal")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if let brightness = display.brightness {
                ControlSlider(title: "Parlaklık", icon: "sun.max", capability: brightness) {
                    if linkedContrastDisplayIDs.contains(display.id) {
                        model.setLinkedBrightness(
                            $0,
                            contrastPercentage: linkedContrastPercentage(for: display),
                            on: display
                        )
                    } else {
                        model.set("luminance", value: $0, on: display)
                    }
                }
            }
            if let contrast = display.contrast {
                if display.kind == .external, display.brightness != nil, !display.writeOnlyFallback {
                    Toggle("Parlaklıkla kontrastı birlikte ayarla", isOn: Binding(
                        get: { linkedContrastDisplayIDs.contains(display.id) },
                        set: { isLinked in
                            if isLinked {
                                linkedContrastDisplayIDs.insert(display.id)
                                if linkedContrastPercentages[display.id] == nil {
                                    linkedContrastPercentages[display.id] = 100
                                }
                                model.synchronizeLinkedContrast(
                                    percentage: linkedContrastPercentage(for: display),
                                    on: display
                                )
                            } else {
                                linkedContrastDisplayIDs.remove(display.id)
                            }
                        }
                    ))
                    .font(.caption)
                    .help("Kontrastı parlaklığın seçilen yüzdesine eşitle")
                }

                if linkedContrastDisplayIDs.contains(display.id) {
                    HStack {
                        Label("Kontrast", systemImage: "circle.lefthalf.filled")
                        Spacer()
                        Text("\(contrast.current)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Kontrast etkisi", systemImage: "dial.medium")
                            .foregroundStyle(.secondary)

                        GlassEffectContainer(spacing: 4) {
                            HStack(spacing: 4) {
                                ForEach(Self.contrastEffectPresets, id: \.self) { preset in
                                    let isSelected = linkedContrastPercentage(for: display) == preset
                                    Button("\(preset)%") {
                                        linkedContrastPercentages[display.id] = preset
                                        model.synchronizeLinkedContrast(percentage: preset, on: display)
                                    }
                                    .buttonStyle(.glass)
                                    .controlSize(.small)
                                    .tint(isSelected ? .accentColor : nil)
                                }

                                TextField(
                                    "50",
                                    value: linkedContrastPercentageBinding(for: display),
                                    formatter: Self.percentageFormatter
                                )
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.center)
                                .monospacedDigit()
                                .frame(width: 26)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .glassEffect(.regular.interactive(), in: .capsule)

                                Text("%")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption)
                } else {
                    ControlSlider(title: "Kontrast", icon: "circle.lefthalf.filled", capability: contrast) {
                        model.set("contrast", value: $0, on: display)
                    }
                }
            }
            if let volume = display.volume {
                ControlSlider(
                    title: "Ses",
                    icon: "speaker.wave.2",
                    capability: volume,
                    isMuted: volume.current == 0 || display.mute == 1,
                    onToggleMute: { model.toggleAudioMute(on: display) }
                ) {
                    model.set("volume", value: $0, on: display)
                }

                if display.kind == .external {
                    Toggle(
                        "Klavye ses tuşlarını bu monitöre yönlendir",
                        isOn: Binding(
                            get: { model.mediaKeyTargetDisplayID == display.id },
                            set: { model.setMediaKeyTarget($0, displayID: display.id) }
                        )
                    )
                    .font(.caption)
                    .help("Ses artırma, azaltma ve sessize alma tuşlarını DDC üzerinden uygula")

                    if model.mediaKeyTargetDisplayID == display.id,
                       model.mediaKeyPermissionRequired {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                "Medya tuşlarını yakalamak için Erişilebilirlik izni gerekiyor.",
                                systemImage: "hand.raised.fill"
                            )
                            .foregroundStyle(.orange)

                            Button("Erişilebilirlik Ayarlarını Aç") {
                                model.openAccessibilitySettings()
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                        .font(.caption2)
                    }
                }
            } else if let mute = display.mute {
                Button {
                    model.set("mute", value: mute == 1 ? 2 : 1, on: display)
                } label: {
                    Label(
                        mute == 1 ? "Sessiz" : "Ses açık",
                        systemImage: mute == 1 ? "speaker.slash.fill" : "speaker.wave.2"
                    )
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
    }

    private func linkedContrastPercentage(for display: DisplayDevice) -> Int {
        linkedContrastPercentages[display.id] ?? 50
    }

    private func linkedContrastPercentageBinding(for display: DisplayDevice) -> Binding<Int> {
        Binding(
            get: { linkedContrastPercentage(for: display) },
            set: {
                let percentage = min(max($0, 0), 100)
                linkedContrastPercentages[display.id] = percentage
                model.synchronizeLinkedContrast(percentage: percentage, on: display)
            }
        )
    }
}

@MainActor
final class MonitorKontrolAppDelegate: NSObject, NSApplicationDelegate {
    private let model = MonitorModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "MonitorKontrol")
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
        }
        statusItem = item

        let hostingController = NSHostingController(
            rootView: MonitorPanel()
                .environmentObject(model)
        )
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.retryMediaKeyCapture()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@main
enum MonitorKontrolApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = MonitorKontrolAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
