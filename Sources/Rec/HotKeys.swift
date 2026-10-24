import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotKey: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers)
    }

    var hasRequiredModifier: Bool {
        carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    var isTakenBySystem: Bool {
        var unmanagedHotKeys: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanagedHotKeys) == noErr,
              let hotKeys = unmanagedHotKeys?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }
        let relevantModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return hotKeys.contains { hotKey in
            guard (hotKey[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let code = hotKey[kHISymbolicHotKeyCode] as? Int,
                  let modifiers = hotKey[kHISymbolicHotKeyModifiers] as? Int else {
                return false
            }
            return UInt32(code) == keyCode && UInt32(modifiers) & relevantModifiers == carbonModifiers
        }
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]

    private static func keyName(for keyCode: UInt32) -> String {
        if let name = specialKeyNames[Int(keyCode)] {
            return name
        }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "#\(keyCode)"
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

enum HotKeyAction: String, CaseIterable {
    case toggleRecording
    case togglePause
    case toggleZoom

    var title: String {
        switch self {
        case .toggleRecording: return "Начать / остановить запись"
        case .togglePause: return "Пауза / продолжить"
        case .toggleZoom: return "Приблизить / отдалить"
        }
    }

    var defaultHotKey: HotKey {
        switch self {
        case .toggleRecording:
            return HotKey(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey))
        case .togglePause:
            return HotKey(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(controlKey | optionKey))
        case .toggleZoom:
            return HotKey(keyCode: UInt32(kVK_ANSI_Z), carbonModifiers: UInt32(controlKey | optionKey))
        }
    }

    fileprivate var storageKey: String { "HotKey.\(rawValue)" }
    fileprivate var hotKeyID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
}

@MainActor
final class HotKeyManager: ObservableObject {
    static let shared = HotKeyManager()

    var onHotKey: (HotKeyAction) -> Void = { _ in }

    nonisolated private static let signature: OSType = 0x5245_4352
    private var registeredRefs: [HotKeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let defaults = UserDefaults.standard

    private init() {}

    func hotKey(for action: HotKeyAction) -> HotKey? {
        guard let data = defaults.data(forKey: action.storageKey) else {
            return action.defaultHotKey
        }
        return try? JSONDecoder().decode(HotKey.self, from: data)
    }

    func start() {
        installEventHandlerIfNeeded()
        registerAll()
    }

    func set(_ hotKey: HotKey, for action: HotKeyAction) -> String? {
        guard hotKey.hasRequiredModifier else { return "Нужна ⌘, ⌥ или ⌃ вместе с клавишей." }
        guard !hotKey.isTakenBySystem else { return "Это сочетание уже занято macOS." }
        guard !HotKeyAction.allCases.contains(where: { $0 != action && self.hotKey(for: $0) == hotKey }) else {
            return "Это сочетание уже используется для другого действия."
        }
        unregister(action)
        guard register(hotKey, for: action) else {
            if let previous = self.hotKey(for: action) {
                _ = register(previous, for: action)
            }
            return "Это сочетание занято другой программой."
        }
        save(hotKey, for: action)
        return nil
    }

    func clear(_ action: HotKeyAction) {
        unregister(action)
        save(nil, for: action)
    }

    func reset(_ action: HotKeyAction) {
        unregister(action)
        defaults.removeObject(forKey: action.storageKey)
        objectWillChange.send()
        if let hotKey = hotKey(for: action) {
            _ = register(hotKey, for: action)
        }
    }

    func suspend() {
        HotKeyAction.allCases.forEach(unregister)
    }

    func resume() {
        registerAll()
    }

    private func registerAll() {
        for action in HotKeyAction.allCases {
            unregister(action)
            if let hotKey = hotKey(for: action) {
                _ = register(hotKey, for: action)
            }
        }
    }

    private func save(_ hotKey: HotKey?, for action: HotKeyAction) {
        objectWillChange.send()
        if let hotKey, let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: action.storageKey)
        } else {
            defaults.set(Data(), forKey: action.storageKey)
        }
    }

    private func register(_ hotKey: HotKey, for action: HotKeyAction) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: action.hotKeyID),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        registeredRefs[action] = ref
        return true
    }

    private func unregister(_ action: HotKeyAction) {
        if let ref = registeredRefs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == HotKeyManager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hotKeyID.id
            Task { @MainActor in
                guard let action = HotKeyAction.allCases.first(where: { $0.hotKeyID == id }) else { return }
                HotKeyManager.shared.onHotKey(action)
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
    }
}

struct HotKeyRecorder: View {
    let action: HotKeyAction
    @Binding var feedback: String?

    @ObservedObject private var manager = HotKeyManager.shared
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(action.title)
            Spacer()
            Button(action: toggleRecording) {
                Text(isRecording ? "Нажмите клавиши…" : (manager.hotKey(for: action)?.displayString ?? "Не задано"))
                    .frame(minWidth: 110)
            }
            Button {
                stopRecording()
                manager.clear(action)
                feedback = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Очистить")
            Button {
                stopRecording()
                manager.reset(action)
                feedback = nil
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("По умолчанию")
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        feedback = nil
        isRecording = true
        manager.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            let hotKey = HotKey(event: event)
            guard hotKey.hasRequiredModifier else {
                feedback = "Нужна ⌘, ⌥ или ⌃ вместе с клавишей."
                return nil
            }
            stopRecording()
            feedback = manager.set(hotKey, for: action)
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        manager.resume()
    }
}
