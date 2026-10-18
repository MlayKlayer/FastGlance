import Carbon.HIToolbox

/// Global shortcuts via Carbon hot keys (no Accessibility permission needed):
/// ⌃⌥1…⌃⌥9 run pinned actions in order, ⌃⌥M toggles the microphone.
@MainActor final class Hotkeys {
    static let shared = Hotkeys()
    static let micID: UInt32 = 100
    static let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// 1...9 for pins, `micID` for the microphone.
    var handler: (UInt32) -> Void = { _ in }
    private var refs: [EventHotKeyRef] = []
    private var installed = false
    private(set) var enabled = false

    func set(enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        guard enabled else { return }
        installHandler()
        let mods = UInt32(controlKey | optionKey)
        for (i, key) in Self.digitKeys.enumerated() { register(key, mods, id: UInt32(i + 1)) }
        register(kVK_ANSI_M, mods, id: Self.micID)
    }

    private func register(_ key: Int, _ mods: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4647_4C4E), id: id)  // 'FGLN'
        if RegisterEventHotKey(UInt32(key), mods, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        } else {
            NSLog("FastGlance: hot key \(id) is taken by another app")
        }
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            MainActor.assumeIsolated { Hotkeys.shared.handler(id.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
