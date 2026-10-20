import CoreAudio
import AudioToolbox
import Foundation

/// Thin typed wrappers over the CoreAudio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ fallback: T) -> T? {
        var a = addr(sel, scope)
        guard AudioObjectHasProperty(obj, &a) else { return nil }
        var v = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
        return status == noErr ? v : nil
    }

    @discardableResult
    static func set<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ value: T) -> Bool {
        var a = addr(sel, scope)
        var v = value
        return withUnsafePointer(to: &v) { AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) } == noErr
    }

    static func settable(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> Bool {
        var a = addr(sel, scope)
        var ok: DarwinBoolean = false
        return AudioObjectHasProperty(obj, &a) && AudioObjectIsPropertySettable(obj, &a, &ok) == noErr && ok.boolValue
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }

    static func array<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, zero: T) -> [T] {
        var a = addr(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var arr = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        guard arr.withUnsafeMutableBytes({ AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0.baseAddress!) }) == noErr else { return [] }
        return arr
    }
}

@MainActor final class AudioSource: DeviceSource {
    struct AudioDev {
        let id: AudioObjectID
        let uid: String
        let name: String
        let transport: UInt32
        let hasOutput: Bool
        let hasInput: Bool
    }

    let prefix = "audio"
    var onChange: (() -> Void)?
    private(set) var devices: [Device] = []
    private(set) var all: [AudioDev] = []
    private(set) var defaultOutput: AudioObjectID = 0
    private(set) var defaultInput: AudioObjectID = 0
    private var observedInputs: Set<AudioObjectID> = []

    func start() {
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var a = CA.addr(sel)
            AudioObjectAddPropertyListenerBlock(CA.system, &a, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        reload()
    }

    func reload() {
        defaultOutput = CA.get(CA.system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) ?? 0
        defaultInput = CA.get(CA.system, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) ?? 0
        all = CA.array(CA.system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, zero: AudioObjectID(0)).compactMap { id in
            guard let uid = CA.string(id, kAudioDevicePropertyDeviceUID),
                  (CA.get(id, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0) == 0
            else { return nil }
            return AudioDev(
                id: id, uid: uid,
                name: CA.string(id, kAudioObjectPropertyName) ?? uid,
                transport: CA.get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0,
                hasOutput: !CA.array(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, zero: AudioStreamID(0)).isEmpty,
                hasInput: !CA.array(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, zero: AudioStreamID(0)).isEmpty)
        }
        // Mute or input level changed by another app or the device itself: keep the mic indicator honest.
        for a in all where a.hasInput && observedInputs.insert(a.id).inserted {
            for sel in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar, kAudioHardwareServiceDeviceProperty_VirtualMainVolume] {
                var addr = CA.addr(sel, kAudioObjectPropertyScopeInput)
                AudioObjectAddPropertyListenerBlock(a.id, &addr, .main) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.reload() }
                }
            }
        }
        // Bluetooth audio is shown on the Bluetooth device itself.
        let next = all.filter { !Self.isBluetooth($0) }.map(device)
        if next != devices { devices = next }
        onChange?()  // default device / mute changes also affect Bluetooth rows and the icon
    }

    static func isBluetooth(_ d: AudioDev) -> Bool {
        d.transport == kAudioDeviceTransportTypeBluetooth || d.transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private func device(_ a: AudioDev) -> Device {
        var roles: [String] = []
        if a.id == defaultOutput { roles.append("Output") }
        if a.id == defaultInput { roles.append("Input") }
        if let v = volume(a.id, kAudioObjectPropertyScopeOutput), a.id == defaultOutput { roles.append("\(Int(v * 100))%") }
        var info = [
            InfoRow("Transport", Self.transportName(a.transport)),
            InfoRow("Direction", [a.hasOutput ? "Output" : nil, a.hasInput ? "Input" : nil].compactMap { $0 }.joined(separator: " + ")),
        ]
        if let rate = CA.get(a.id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)) {
            info.append(InfoRow("Sample rate", "\(Int(rate)) Hz"))
        }
        if let model = CA.string(a.id, kAudioDevicePropertyModelUID) { info.append(InfoRow("Model UID", model)) }
        return Device(id: "audio:\(a.uid)", name: a.name, kind: .audio, isConnected: true,
                      status: roles.isEmpty ? "Available" : roles.joined(separator: " · "),
                      info: info, raw: [InfoRow("UID", a.uid), InfoRow("Object ID", "\(a.id)")],
                      symbol: a.hasInput && !a.hasOutput ? "mic" : nil)
    }

    private func dev(for device: Device) -> AudioDev? {
        all.first { "audio:\($0.uid)" == device.id }
    }

    func actions(for device: Device) -> [DeviceAction] {
        guard let a = dev(for: device) else { return [] }
        return actions(for: a, device: device)
    }

    /// Shared with Bluetooth rows, which own their audio devices.
    func actions(for a: AudioDev, device: Device) -> [DeviceAction] {
        // Already-active choices stay listed (last, with a checkmark) so a pin to them never goes missing.
        var out: [DeviceAction] = []
        var active: [DeviceAction] = []
        func add(_ key: String, _ title: String, _ symbol: String, isActive: Bool, _ run: @escaping () -> Void) {
            if isActive { active.append(DeviceAction(device, key, title, "checkmark.circle", run: run)) }
            else { out.append(DeviceAction(device, key, title, symbol, run: run)) }
        }
        let isOutput = a.id == defaultOutput, isInput = a.id == defaultInput
        if a.hasOutput {
            add("output", "Use for Output", "speaker.wave.2", isActive: isOutput) { [weak self] in self?.setDefault(output: a.id) }
        }
        if a.hasInput {
            add("input", "Use for Input", "mic", isActive: isInput) { [weak self] in self?.setDefault(input: a.id) }
        }
        if a.hasOutput && a.hasInput {
            add("both", "Use for Input & Output", "arrow.left.arrow.right", isActive: isOutput && isInput) { [weak self] in
                self?.setDefault(output: a.id); self?.setDefault(input: a.id)
            }
        }
        if a.hasOutput, let muted = mute(a.id, kAudioObjectPropertyScopeOutput) {
            out.append(DeviceAction(device, "mute", muted ? "Unmute" : "Mute", muted ? "speaker.wave.2" : "speaker.slash") { [weak self] in
                self?.setMute(a.id, kAudioObjectPropertyScopeOutput, !muted)
            })
        }
        return out + active
    }

    func controls(for device: Device) -> [DeviceControl] {
        guard let a = dev(for: device) else { return [] }
        return controls(for: a)
    }

    func controls(for a: AudioDev) -> [DeviceControl] {
        var out: [DeviceControl] = []
        for (scope, title, symbol) in [(kAudioObjectPropertyScopeOutput, "Volume", "speaker.wave.2"), (kAudioObjectPropertyScopeInput, "Input level", "mic")]
        where volume(a.id, scope) != nil && canSetVolume(a.id, scope) {
            out.append(DeviceControl(id: "\(a.uid)|vol\(scope)", title: title, symbol: symbol, kind: .slider(
                get: { [weak self] in Double(self?.volume(a.id, scope) ?? 0) },
                set: { [weak self] in self?.setVolume(a.id, scope, Float32($0)) })))
        }
        let rates = CA.array(a.id, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, zero: AudioValueRange())
            .map(\.mMinimum).filter { $0 > 0 }
        if rates.count > 1 {
            out.append(DeviceControl(id: "\(a.uid)|rate", title: "Sample rate", symbol: "waveform", kind: .picker(
                options: rates.map { "\(Int($0)) Hz" },
                get: { rates.firstIndex(of: CA.get(a.id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)) ?? 0) ?? 0 },
                set: { CA.set(a.id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, rates[$0]) })))
        }
        return out
    }

    func sections(for device: Device) -> [InfoSection] {
        guard let a = dev(for: device) else { return [] }
        return sections(for: a)
    }

    /// Hardware details straight from the HAL. Shared with Bluetooth rows.
    func sections(for a: AudioDev) -> [InfoSection] {
        let global = kAudioObjectPropertyScopeGlobal
        let rate = CA.get(a.id, kAudioDevicePropertyNominalSampleRate, global, Float64(0)) ?? 0
        func frames(_ n: UInt32) -> String {
            rate > 0 ? String(format: "%d frames (%.2f ms)", n, Double(n) / rate * 1000) : "\(n) frames"
        }
        var out: [InfoSection] = []
        for (scope, title) in [(kAudioObjectPropertyScopeOutput, "Output"), (kAudioObjectPropertyScopeInput, "Input")] {
            let streams = CA.array(a.id, kAudioDevicePropertyStreams, scope, zero: AudioStreamID(0))
            guard let stream = streams.first else { continue }
            let count = channelCount(a.id, scope)
            var rows = [InfoRow("Channels", "\(count) in \(streams.count) stream\(streams.count == 1 ? "" : "s")")]
            // Many drivers just echo the channel number back; only real names are worth a row.
            let names = (1...max(count, 1)).map { ch in channelName(a.id, scope, UInt32(ch)).flatMap { $0 == "\(ch)" ? nil : $0 } }
            if names.contains(where: { $0 != nil }) {
                rows.append(InfoRow("Channel names", names.enumerated().map { "\($0 + 1): \($1 ?? "—")" }.joined(separator: ", ")))
            }
            if let f = CA.get(stream, kAudioStreamPropertyPhysicalFormat, global, AudioStreamBasicDescription()) {
                rows.append(InfoRow("Hardware format", Self.formatName(bits: f.mBitsPerChannel, flags: f.mFormatFlags)))
            }
            let device = CA.get(a.id, kAudioDevicePropertyLatency, scope, UInt32(0)) ?? 0
            let safety = CA.get(a.id, kAudioDevicePropertySafetyOffset, scope, UInt32(0)) ?? 0
            let streamLatency = CA.get(stream, kAudioStreamPropertyLatency, global, UInt32(0)) ?? 0
            rows += [InfoRow("Device latency", frames(device)), InfoRow("Stream latency", frames(streamLatency)),
                     InfoRow("Safety offset", frames(safety)),
                     InfoRow("Fixed latency", frames(device + streamLatency + safety) + ", plus each app's buffer")]
            out.append(InfoSection(title: title, rows: rows))
        }

        var clock: [InfoRow] = []
        let rates = CA.array(a.id, kAudioDevicePropertyAvailableNominalSampleRates, global, zero: AudioValueRange())
        if !rates.isEmpty { clock.append(InfoRow("Sample rates", Self.rateList(rates))) }
        if let r = CA.get(a.id, kAudioDevicePropertyBufferFrameSizeRange, global, AudioValueRange()) {
            clock.append(InfoRow("Buffer range", "\(Int(r.mMinimum))–\(Int(r.mMaximum)) frames (each app picks its own)"))
        }
        for scope in [global, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
            guard let src = CA.get(a.id, kAudioDevicePropertyClockSource, scope, UInt32(0)) else { continue }
            clock.append(InfoRow("Clock source", clockSourceName(a.id, scope, src) ?? "ID \(src)"))
            break
        }
        if let running = CA.get(a.id, kAudioDevicePropertyDeviceIsRunningSomewhere, global, UInt32(0)) {
            clock.append(InfoRow("In use by an app", running != 0 ? "Yes" : "No"))
        }
        if !clock.isEmpty { out.append(InfoSection(title: "Clock & Buffer", rows: clock)) }
        return out
    }

    private func channelCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = CA.addr(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func channelName(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope, _ channel: UInt32) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyElementName, mScope: scope, mElement: channel)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() as String?, !s.isEmpty else { return nil }
        return s
    }

    private func clockSourceName(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope, _ source: UInt32) -> String? {
        var a = CA.addr(kAudioDevicePropertyClockSourceNameForIDCFString, scope)
        var input = source
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let status = withUnsafeMutablePointer(to: &input) { inPtr in
            withUnsafeMutablePointer(to: &cf) { outPtr in
                var t = AudioValueTranslation(mInputData: inPtr, mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                                              mOutputData: outPtr, mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
                return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t)
            }
        }
        guard status == noErr else { return nil }
        return cf?.takeRetainedValue() as String?
    }

    nonisolated static func formatName(bits: UInt32, flags: AudioFormatFlags) -> String {
        let float = flags & kAudioFormatFlagIsFloat != 0
        return bits == 0 ? "Compressed" : "\(bits)-bit \(float ? "float" : "integer")"
    }

    /// "44.1, 48, 96 kHz", or a range when the device takes any rate in between.
    nonisolated static func rateList(_ ranges: [AudioValueRange]) -> String {
        func k(_ v: Float64) -> String { v.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(v / 1000))" : String(format: "%.1f", v / 1000) }
        let parts = ranges.sorted { $0.mMinimum < $1.mMinimum }.map {
            $0.mMinimum == $0.mMaximum ? k($0.mMinimum) : "\(k($0.mMinimum))–\(k($0.mMaximum))"
        }
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: ", ") + " kHz"
    }

    // MARK: - Operations

    func setDefault(output id: AudioObjectID) {
        CA.set(CA.system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, id)
        CA.set(CA.system, kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioObjectPropertyScopeGlobal, id)
    }

    func setDefault(input id: AudioObjectID) {
        CA.set(CA.system, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, id)
    }

    func outputs(forBluetoothAddress addr: String) -> [AudioDev] {
        all.filter { $0.hasOutput && $0.uid.lowercased().hasPrefix(addr) }
    }

    func volume(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Float32? {
        CA.get(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, Float32(0))
            ?? CA.get(id, kAudioDevicePropertyVolumeScalar, scope, Float32(0))
    }

    private func canSetVolume(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        CA.settable(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope) || CA.settable(id, kAudioDevicePropertyVolumeScalar, scope)
    }

    func setVolume(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope, _ v: Float32) {
        if !CA.set(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope, v) {
            CA.set(id, kAudioDevicePropertyVolumeScalar, scope, v)
        }
    }

    func mute(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool? {
        guard CA.settable(id, kAudioDevicePropertyMute, scope) else { return nil }
        return CA.get(id, kAudioDevicePropertyMute, scope, UInt32(0)).map { $0 != 0 }
    }

    func setMute(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope, _ on: Bool) {
        CA.set(id, kAudioDevicePropertyMute, scope, UInt32(on ? 1 : 0))
        reload()
    }

    // MARK: - Global microphone mute

    private let savedMicVolumesKey = "savedMicVolumes"  // device UID -> input level before muting
    private let mutedMicsKey = "mutedMics"              // UIDs whose mute switch we turned on

    var isMicMuted: Bool {
        guard defaultInput != 0 else { return false }
        if let m = mute(defaultInput, kAudioObjectPropertyScopeInput) { return m }
        return volume(defaultInput, kAudioObjectPropertyScopeInput) == 0
    }

    /// Mutes every real microphone, not just the default one, so an app recording from another mic is silenced too.
    /// Unmuting restores only what was muted here (plus the default mic), so a mic the user muted stays muted.
    /// a mic plugged in while muted starts unmuted; toggle twice to catch it.
    func toggleMic() {
        guard defaultInput != 0 else { return }
        let scope = kAudioObjectPropertyScopeInput
        let d = UserDefaults.standard
        var flipped = Set(d.stringArray(forKey: mutedMicsKey) ?? [])
        var levels = d.dictionary(forKey: savedMicVolumesKey) as? [String: Double] ?? [:]
        if !isMicMuted {
            // Virtual inputs (BlackHole, Zoom/Teams audio) are left alone so screen-recording audio keeps working.
            for a in all where a.hasInput && (a.id == defaultInput || !Self.isVirtual(a)) {
                if let muted = mute(a.id, scope) {
                    if !muted { CA.set(a.id, kAudioDevicePropertyMute, scope, UInt32(1)); flipped.insert(a.uid) }
                } else if canSetVolume(a.id, scope), let level = volume(a.id, scope), level > 0 {
                    // No mute switch on this device: drop the input level to zero and restore it later.
                    levels[a.uid] = Double(level)
                    setVolume(a.id, scope, 0)
                }
            }
        } else {
            for a in all where a.hasInput && (a.id == defaultInput || flipped.contains(a.uid) || levels[a.uid] != nil) {
                if mute(a.id, scope) != nil {
                    CA.set(a.id, kAudioDevicePropertyMute, scope, UInt32(0))
                } else if volume(a.id, scope) == 0 {
                    setVolume(a.id, scope, Float32(levels[a.uid] ?? 0.75))
                }
            }
            flipped = []
            levels = [:]
        }
        d.set(Array(flipped), forKey: mutedMicsKey)
        d.set(levels, forKey: savedMicVolumesKey)
        reload()
    }

    static func isVirtual(_ d: AudioDev) -> Bool {
        d.transport == kAudioDeviceTransportTypeVirtual || d.transport == kAudioDeviceTransportTypeAggregate
    }

    static func transportName(_ t: UInt32) -> String {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: "Built-in"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual: "Virtual"
        case kAudioDeviceTransportTypeAggregate: "Aggregate"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: "Continuity"
        default: "Other"
        }
    }
}
