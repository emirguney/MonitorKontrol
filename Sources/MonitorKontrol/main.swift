import AppKit
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
    var standardInput: Int?
    var lgInput: Int?
    var writeOnlyFallback: Bool
}

struct CommandResult: Sendable {
    let status: Int32
    let output: String
    var succeeded: Bool { status == 0 }
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
            let standardInput = probeControls ? probeValue(index: index, command: "input") : nil
            let lgInput = probeControls ? probeValue(index: index, command: "input-alt") : nil
            let needsWriteOnlyFallback = brightness == nil || contrast == nil || volume == nil ||
                mute == nil || standardInput == nil || lgInput == nil

            devices.append(DisplayDevice(
                id: String(line[idRange]),
                index: index,
                name: displayName,
                kind: .external,
                brightness: brightness ?? (needsWriteOnlyFallback ? NumericCapability(current: 50, maximum: 100) : nil),
                contrast: contrast ?? (needsWriteOnlyFallback ? NumericCapability(current: 50, maximum: 100) : nil),
                volume: volume ?? (needsWriteOnlyFallback ? NumericCapability(current: 50, maximum: 100) : nil),
                mute: mute ?? (needsWriteOnlyFallback ? 2 : nil),
                standardInput: standardInput ?? (needsWriteOnlyFallback ? 17 : nil),
                lgInput: lgInput ?? (needsWriteOnlyFallback ? 144 : nil),
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
            standardInput: nil,
            lgInput: nil,
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

    private let client = DDCClient()
    private let builtInController = BuiltInDisplayController()
    private var displayObserver: DisplayChangeObserver?

    init() {
        displayObserver = DisplayChangeObserver { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        displayObserver?.start()
        refresh()
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
            isRefreshing = false
            lastError = error
            if externalDisplays.isEmpty, builtIn != nil {
                status = "Dahili ekran hazır"
            } else if externalDisplays.isEmpty {
                status = "Ekran bulunamadı"
            } else {
                status = "\(externalDisplays.count) harici monitör bulundu"
            }
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
                standardInput: previous.standardInput,
                lgInput: previous.lgInput,
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
            lastError = nil
        }
    }

    private func update(displayID: String, command: String, value: Int) {
        guard let position = displays.firstIndex(where: { $0.id == displayID }) else { return }
        switch command {
        case "luminance": displays[position].brightness?.current = value
        case "contrast": displays[position].contrast?.current = value
        case "volume": displays[position].volume?.current = value
        case "mute": displays[position].mute = value
        case "input": displays[position].standardInput = value
        case "input-alt": displays[position].lgInput = value
        default: break
        }
    }
}

struct ControlSlider: View {
    let title: String
    let icon: String
    let capability: NumericCapability
    let onCommit: (Int) -> Void
    @State private var value: Double

    init(title: String, icon: String, capability: NumericCapability, onCommit: @escaping (Int) -> Void) {
        self.title = title
        self.icon = icon
        self.capability = capability
        self.onCommit = onCommit
        _value = State(initialValue: Double(capability.current))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: icon)
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
        }
        .onChange(of: capability.current) { _, newValue in value = Double(newValue) }
    }
}

struct InputSelector: View {
    let title: String
    let current: Int
    let options: [(String, Int)]
    let onSelect: (Int) -> Void

    var body: some View {
        HStack {
            Label(title, systemImage: "rectangle.connected.to.line.below")
            Spacer()
            Menu(inputName(current)) {
                ForEach(options, id: \.1) { option in
                    Button(option.0) { onSelect(option.1) }
                }
            }
        }
    }

    private func inputName(_ value: Int) -> String {
        options.first(where: { $0.1 == value })?.0 ?? "Kod \(value)"
    }
}

struct MonitorPanel: View {
    @EnvironmentObject private var model: MonitorModel
    @State private var expandedDisplayIDs: Set<String> = []
    @State private var knownDisplayIDs: Set<String> = []

    private let standardInputs = [
        ("DisplayPort 1", 15), ("DisplayPort 2", 16),
        ("HDMI 1", 17), ("HDMI 2", 18), ("USB-C", 27)
    ]
    private let lgInputs = [
        ("DisplayPort 1", 208), ("DisplayPort 2", 209),
        ("HDMI 1", 144), ("HDMI 2", 145), ("USB-C / DP 3", 210)
    ]

    var body: some View {
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
                .buttonStyle(.borderless)
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
        .frame(width: 360)
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
                    model.set("luminance", value: $0, on: display)
                }
            }
            if let contrast = display.contrast {
                ControlSlider(title: "Kontrast", icon: "circle.lefthalf.filled", capability: contrast) {
                    model.set("contrast", value: $0, on: display)
                }
            }
            if let volume = display.volume {
                ControlSlider(title: "Ses", icon: "speaker.wave.2", capability: volume) {
                    model.set("volume", value: $0, on: display)
                }
            }
            if let mute = display.mute {
                Toggle("Sessiz", isOn: Binding(
                    get: { mute == 1 },
                    set: { model.set("mute", value: $0 ? 1 : 2, on: display) }
                ))
            }
            if let input = display.standardInput {
                InputSelector(title: "Giriş", current: input, options: standardInputs) {
                    model.set("input", value: $0, on: display)
                }
            }
            if let input = display.lgInput {
                InputSelector(title: "LG girişi", current: input, options: lgInputs) {
                    model.set("input-alt", value: $0, on: display)
                }
            }
        }
    }
}

@MainActor
final class MonitorKontrolAppDelegate: NSObject, NSApplicationDelegate {
    private let model = MonitorModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

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
                .background(Color(nsColor: .windowBackgroundColor))
        )
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = false
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
