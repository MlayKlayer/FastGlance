import SwiftUI
import DiskArbitration

@MainActor final class DiskSource: DeviceSource {
    struct VerifyResult: Hashable {
        let ok: Bool
        let summary: String
        let date: Date
    }

    /// A volume macOS has attached, mounted or not, as Disk Arbitration describes it.
    private struct Volume {
        let bsd: String
        let uuid: String
        let name: String
        let path: URL?
        let whole: String?
        let size: Int
    }

    let prefix = "disk"
    var onChange: (() -> Void)?
    private(set) var devices: [Device] = []
    private var urls: [String: URL] = [:]
    private var localIDs: Set<String> = []
    private var bsdNames: [String: String] = [:]   // device id -> volume BSD name
    private var attached: [String: Volume] = [:]   // BSD name -> volume
    private var session: DASession?
    private var reloadQueued = false
    /// Volumes that were mounted and shown here before. Only these keep a row while unmounted,
    /// so partitions macOS never mounts (EFI, APFS system roles) stay out.
    private var known = Set(UserDefaults.standard.stringArray(forKey: "knownVolumeUUIDs") ?? [])
    private var details: [String: [InfoSection]] = [:]
    private var health: [String: (text: String, failing: Bool)] = [:]
    /// Device id -> BSD name of the physical whole disk (for APFS, the disk under the container).
    private(set) var physicalDisks: [String: String] = [:]
    private(set) var verifying: Set<String> = []
    private(set) var verifyResults: [String: VerifyResult] = [:]

    private let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsInternalKey, .volumeIsEjectableKey,
                                          .volumeIsRemovableKey, .volumeIsLocalKey, .volumeTotalCapacityKey,
                                          .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey]

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        }
        if let s = DASessionCreate(kCFAllocatorDefault) {
            session = s
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            DARegisterDiskAppearedCallback(s, nil, { disk, ctx in
                MainActor.assumeIsolated { Unmanaged<DiskSource>.fromOpaque(ctx!).takeUnretainedValue().update(disk) }
            }, ctx)
            DARegisterDiskDescriptionChangedCallback(s, nil, nil, { disk, _, ctx in
                MainActor.assumeIsolated { Unmanaged<DiskSource>.fromOpaque(ctx!).takeUnretainedValue().update(disk) }
            }, ctx)
            DARegisterDiskDisappearedCallback(s, nil, { disk, ctx in
                MainActor.assumeIsolated { Unmanaged<DiskSource>.fromOpaque(ctx!).takeUnretainedValue().remove(disk) }
            }, ctx)
            DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        reload()
    }

    // MARK: - Disk Arbitration

    private func update(_ disk: DADisk) {
        guard let bsdPtr = DADiskGetBSDName(disk) else { return }
        let bsd = String(cString: bsdPtr)
        let d = DADiskCopyDescription(disk) as? [String: Any] ?? [:]
        guard let raw = d[kDADiskDescriptionVolumeUUIDKey as String], CFGetTypeID(raw as CFTypeRef) == CFUUIDGetTypeID() else {
            attached[bsd] = nil
            return
        }
        let whole = DADiskCopyWholeDisk(disk).flatMap { DADiskGetBSDName($0) }.map { String(cString: $0) }
        attached[bsd] = Volume(bsd: bsd, uuid: CFUUIDCreateString(nil, (raw as! CFUUID)) as String,
                               name: d[kDADiskDescriptionVolumeNameKey as String] as? String ?? bsd,
                               path: d[kDADiskDescriptionVolumePathKey as String] as? URL,
                               whole: whole,
                               size: (d[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.intValue ?? 0)
        queueReload()
    }

    private func remove(_ disk: DADisk) {
        guard let bsdPtr = DADiskGetBSDName(disk) else { return }
        attached[String(cString: bsdPtr)] = nil
        queueReload()
    }

    /// Disk Arbitration reports every partition separately; one reload per burst is enough.
    private func queueReload() {
        guard !reloadQueued else { return }
        reloadQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadQueued = false
            self?.reload()
        }
    }

    // MARK: - Devices

    func reload() { reload(fetchDetails: true) }

    private func reload(fetchDetails: Bool) {
        var next: [Device] = []
        var nextURLs: [String: URL] = [:]
        var nextLocal: Set<String> = []
        var nextBSD: [String: String] = [:]
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let isInternal = v.volumeIsInternal ?? false
            let ejectable = v.volumeIsEjectable ?? false
            guard !isInternal || ejectable else { continue }
            let id = "disk:\(v.volumeUUIDString ?? url.path)"
            let total = v.volumeTotalCapacity ?? 0
            let free = v.volumeAvailableCapacity ?? 0
            nextURLs[id] = url
            if v.volumeIsLocal ?? true { nextLocal.insert(id) }
            if let uuid = v.volumeUUIDString {
                known.insert(uuid)
                nextBSD[id] = attached.values.first { $0.uuid == uuid }?.bsd ?? USBDoctor.bsdName(forVolume: url)
            }
            let doctor = USBDoctor.bsdName(forVolume: url).flatMap(USBDoctor.report(bsdName:))
            var extra: [InfoRow] = []
            if let doctor {
                extra.append(InfoRow("Connection", doctor.link))
                if !doctor.via.isEmpty { extra.append(InfoRow("Through", doctor.via.joined(separator: " → "))) }
                if let note = doctor.note { extra.append(InfoRow("Note", note)) }
            }
            if let h = health[id] { extra.append(InfoRow("Health", h.text)) }
            next.append(Device(
                id: id, name: v.volumeName ?? url.lastPathComponent, kind: .storage, isConnected: true,
                status: total > 0 ? "\(Util.bytes(free)) free of \(Util.bytes(total))" : nil,
                info: [InfoRow("Mounted at", url.path),
                       InfoRow("Format", v.volumeLocalizedFormatDescription ?? "—"),
                       InfoRow("Capacity", Util.bytes(total)),
                       InfoRow("Available", Util.bytes(free)),
                       InfoRow("Location", (v.volumeIsLocal ?? true) ? "Local" : "Network"),
                       InfoRow("Removable", (v.volumeIsRemovable ?? false) ? "Yes" : "No")] + extra,
                raw: [InfoRow("UUID", v.volumeUUIDString ?? "—")],
                warning: health[id]?.failing == true ? "The drive reports that it is failing. Copy anything important off it now." : doctor?.warning))
        }
        // Attached but unmounted (by Unmount, Lid Guard, Finder or Disk Utility): the row stays, with Mount.
        for v in attached.values.sorted(by: { $0.bsd < $1.bsd }) where v.path == nil && known.contains(v.uuid) {
            let id = "disk:\(v.uuid)"
            guard nextURLs[id] == nil else { continue }
            nextBSD[id] = v.bsd
            var info = [InfoRow("Mounted at", "Not mounted"), InfoRow("Capacity", Util.bytes(v.size)), InfoRow("Device", v.bsd)]
            if let h = health[id] { info.append(InfoRow("Health", h.text)) }
            next.append(Device(id: id, name: v.name, kind: .storage, isConnected: true, status: "Not mounted",
                               info: info, raw: [InfoRow("UUID", v.uuid)]))
        }
        urls = nextURLs
        localIDs = nextLocal
        bsdNames = nextBSD
        let list = Array(known)
        if list.count != (UserDefaults.standard.stringArray(forKey: "knownVolumeUUIDs") ?? []).count {
            UserDefaults.standard.set(list, forKey: "knownVolumeUUIDs")
        }
        if next != devices { devices = next; onChange?() }
        if fetchDetails { refreshDetails() }
    }

    /// `diskutil info` takes tens of milliseconds per disk, so it runs in the background and the rows update when it's back.
    private func refreshDetails() {
        let targets = bsdNames
        DispatchQueue.global(qos: .utility).async {
            var out: [String: [InfoSection]] = [:]
            var healthOut: [String: (text: String, failing: Bool)] = [:]
            var physical: [String: String] = [:]
            for (id, bsd) in targets {
                let vol = Self.plist(["info", "-plist", bsd])
                guard !vol.isEmpty else { continue }
                // APFS volumes sit in a synthesized container; the hardware is under its physical store.
                let store = (vol["APFSPhysicalStores"] as? [[String: Any]])?.first?["APFSPhysicalStore"] as? String
                let wholeName = store.flatMap { Self.plist(["info", "-plist", $0])["ParentWholeDisk"] as? String }
                    ?? vol["ParentWholeDisk"] as? String
                let whole = wholeName.map { Self.plist(["info", "-plist", $0]) } ?? [:]
                let list = wholeName.map { Self.plist(["list", "-plist", $0]) } ?? [:]
                out[id] = Self.describe(volume: vol, whole: whole, list: list)
                healthOut[id] = Self.health(whole.isEmpty ? vol : whole)
                if let wholeName { physical[id] = wholeName }
            }
            DispatchQueue.main.async { [out, healthOut, physical] in
                MainActor.assumeIsolated {
                    let healthChanged = healthOut.mapValues(\.text) != self.health.mapValues(\.text)
                    guard out != self.details || healthChanged || physical != self.physicalDisks else { return }
                    self.details = out
                    self.health = healthOut
                    self.physicalDisks = physical
                    self.reload(fetchDetails: false)
                    self.onChange?()
                }
            }
        }
    }

    nonisolated private static func plist(_ args: [String]) -> [String: Any] {
        let data = Util.output("/usr/sbin/diskutil", args)
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
    }

    func sections(for device: Device) -> [InfoSection] { details[device.id] ?? [] }

    func tools(for device: Device) -> [DeviceTool] {
        guard bsdNames[device.id] != nil else { return [] }
        var out = [DeviceTool(id: "disk.verify", title: "Verify Volume", symbol: "checkmark.shield") { [unowned self] in
            AnyView(VerifyTool(disks: self, device: device, running: verifying.contains(device.id), result: verifyResults[device.id]))
        }]
        if let whole = physicalDisks[device.id] {
            out.append(DeviceTool(id: "disk.activity", title: "Activity", symbol: "chart.line.uptrend.xyaxis") {
                AnyView(DiskActivityTool(bsd: whole))
            })
        }
        return out
    }

    /// 0...1 used fraction, for the capacity bar.
    func usage(_ device: Device) -> Double? {
        guard let url = urls[device.id], let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = v.volumeTotalCapacity, total > 0, let free = v.volumeAvailableCapacity else { return nil }
        return 1 - Double(free) / Double(total)
    }

    // MARK: - Actions

    func actions(for device: Device) -> [DeviceAction] {
        guard let bsd = bsdNames[device.id] ?? (urls[device.id] != nil ? "" : nil) else { return [] }
        let url = urls[device.id]
        let id = device.id
        // While Verify runs the volume may be unmounted underneath us; everything else waits.
        func guarded(_ run: @escaping () -> Void) -> () -> Void {
            { [weak self] in
                if self?.verifying.contains(id) == true {
                    Notifier.shared.report(id, device.name, "Wait for Verify to finish", failed: true)
                } else {
                    run()
                }
            }
        }
        let eject = DeviceAction(device, "eject", "Eject", "eject", run: guarded { [weak self] in
            if let url { self?.eject(url, device) } else { self?.ejectUnmounted(bsd, device) }
        })
        guard !bsd.isEmpty else {  // network share or a volume without a BSD name: eject only, as before
            return [eject] + (url.map { url in [DeviceAction(device, "open", "Open in Finder", "folder") { NSWorkspace.shared.open(url) },
                                                DeviceAction(device, "copypath", "Copy Path", "doc.on.doc") { Util.copy(url.path) }] } ?? [])
        }
        let mount = DeviceAction(device, "mount", url == nil ? "Mount" : "Unmount", url == nil ? "externaldrive.badge.plus" : "externaldrive.badge.minus",
                                 run: guarded { [weak self] in
            if let url { self?.unmount(bsd, url, device) } else { self?.mount(bsd, device) }
        })
        guard let url else { return [mount, eject] }
        return [eject, mount,
                DeviceAction(device, "open", "Open in Finder", "folder") { NSWorkspace.shared.open(url) },
                DeviceAction(device, "copypath", "Copy Path", "doc.on.doc") { Util.copy(url.path) }]
    }

    var hasEjectable: Bool { !urls.isEmpty }

    /// Mounted external volumes on this Mac (not network shares), for unmounting before sleep. Volumes being verified are left alone.
    var localVolumes: [(url: URL, name: String, uuid: String?)] {
        devices.compactMap { d in
            guard localIDs.contains(d.id), !verifying.contains(d.id), let url = urls[d.id] else { return nil }
            let uuid = d.raw.first { $0.key == "UUID" }?.value
            return (url, d.name, uuid == "—" ? nil : uuid)
        }
    }

    var verifyingNames: [String] { devices.filter { verifying.contains($0.id) }.map(\.name) }

    func ejectAll() {
        for d in devices where !verifying.contains(d.id) { if let url = urls[d.id] { eject(url, d) } }
    }

    private func eject(_ url: URL, _ d: Device) {
        let (id, name) = (d.id, d.name)
        Notifier.shared.report(id, name, "Ejecting…")
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                message = nil
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async {
                if let message {
                    Notifier.shared.report(id, name, "Couldn't eject: \(message)", failed: true) { [weak self] in self?.eject(url, d) }
                } else {
                    Notifier.shared.report(id, name, "Ejected · safe to unplug", lasts: 60)
                }
            }
        }
    }

    private func ejectUnmounted(_ bsd: String, _ d: Device) {
        let (id, name) = (d.id, d.name)
        let whole = attached[bsd]?.whole ?? bsd
        Notifier.shared.report(id, name, "Ejecting…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Util.exec("/usr/sbin/diskutil", ["eject", whole])
            DispatchQueue.main.async {
                if r.status == 0 {
                    Notifier.shared.report(id, name, "Ejected · safe to unplug", lasts: 60)
                } else {
                    Notifier.shared.report(id, name, "Couldn't eject: \(Self.lastLine(r.output))", failed: true) { [weak self] in
                        self?.ejectUnmounted(bsd, d)
                    }
                }
            }
        }
    }

    private func mount(_ bsd: String, _ d: Device) {
        let (id, name) = (d.id, d.name)
        Notifier.shared.report(id, name, "Mounting…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Util.exec("/usr/sbin/diskutil", ["mount", bsd])
            DispatchQueue.main.async {
                if r.status == 0 {
                    Notifier.shared.report(id, name, "Mounted")
                } else {
                    Notifier.shared.report(id, name, "Couldn't mount: \(Self.lastLine(r.output))", failed: true) { [weak self] in self?.mount(bsd, d) }
                }
            }
        }
    }

    /// Never forced: a volume that's in use stays mounted, and the row says which apps are holding it.
    private func unmount(_ bsd: String, _ url: URL, _ d: Device) {
        let (id, name) = (d.id, d.name)
        Notifier.shared.report(id, name, "Unmounting…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Util.exec("/usr/sbin/diskutil", ["unmount", bsd])
            let users = r.status == 0 ? [] : Self.users(of: url)
            DispatchQueue.main.async {
                if r.status == 0 {
                    Notifier.shared.report(id, name, "Unmounted · still attached", lasts: 10)
                } else {
                    let why = users.isEmpty ? Self.lastLine(r.output) : "in use by \(users.joined(separator: ", "))"
                    Notifier.shared.report(id, name, "Couldn't unmount: \(why)", failed: true) { [weak self] in self?.unmount(bsd, url, d) }
                }
            }
        }
    }

    // MARK: - Verify

    /// Mounted volume: the apps with files open on it, so the confirmation can name them. Off the main thread.
    func users(of device: Device, completion: @escaping @MainActor ([String]) -> Void) {
        guard let url = urls[device.id] else { return completion([]) }
        DispatchQueue.global(qos: .userInitiated).async {
            let users = Self.users(of: url)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(users) } }
        }
    }

    func isMounted(_ device: Device) -> Bool { urls[device.id] != nil }

    func verify(_ device: Device) {
        guard let bsd = bsdNames[device.id], !bsd.isEmpty, !verifying.contains(device.id) else { return }
        let (id, name) = (device.id, device.name)
        verifying.insert(id)
        onChange?()
        Notifier.shared.report(id, name, "Verifying…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Util.exec("/usr/sbin/diskutil", ["verifyVolume", bsd])
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.verifying.remove(id)
                    let result = VerifyResult(ok: r.status == 0, summary: Self.verifySummary(r.output), date: Date())
                    self.verifyResults[id] = result
                    Notifier.shared.report(id, name, result.ok ? "Verify: no problems found" : "Verify found problems",
                                           failed: !result.ok, notify: true)
                    self.reload()
                    self.onChange?()
                }
            }
        }
    }

    // MARK: - Parsing

    nonisolated private static func users(of url: URL) -> [String] {
        // A mount point as the argument makes lsof list every open file on that file system.
        lsofCommands(Util.exec("/usr/sbin/lsof", ["-F", "c", url.path]).output)
    }

    /// `lsof -F c` output: "p123" / "cPreview" pairs. Unique command names, sorted.
    nonisolated static func lsofCommands(_ text: String) -> [String] {
        Array(Set(text.split(separator: "\n").filter { $0.hasPrefix("c") }.map { String($0.dropFirst()) })).sorted()
    }

    nonisolated static func lastLine(_ text: String) -> String {
        text.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "unknown error"
    }

    /// The lines worth showing from `diskutil verifyVolume`: findings and the verdict, without the step-by-step progress.
    nonisolated static func verifySummary(_ text: String) -> String {
        let chatter = ["Started", "Finished", "Verifying", "Performing", "Checking", "Rechecking", "Volume was successfully",
                       "Restoring", "Volume name is", "File system check exit code"]
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in !line.isEmpty && !chatter.contains { line.hasPrefix($0) } && !line.contains("was formatted by") }
        return lines.suffix(8).joined(separator: "\n")
    }

    nonisolated static func health(_ disk: [String: Any]) -> (text: String, failing: Bool) {
        let smart = disk["SMARTStatus"] as? String ?? "Not Supported"
        let used = (disk["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any])?["PERCENTAGE_USED"] as? Int
        switch smart {
        case "Verified": return ("SMART verified" + (used.map { " · \($0)% worn" } ?? ""), false)
        case "Failing": return ("SMART failing", true)
        default: return ("Not reported by this drive", false)
        }
    }

    nonisolated static func describe(volume v: [String: Any], whole w: [String: Any], list: [String: Any]) -> [InfoSection] {
        func yes(_ b: Bool) -> String { b ? "Yes" : "No" }
        var vol: [InfoRow] = []
        if let s = v["DeviceIdentifier"] as? String { vol.append(InfoRow("Device", s)) }
        if let s = v["FilesystemUserVisibleName"] as? String { vol.append(InfoRow("File system", s)) }
        vol.append(InfoRow("Mount point", v["MountPoint"] as? String ?? "Not mounted"))
        if v["MountPoint"] != nil, let w = v["WritableVolume"] as? Bool { vol.append(InfoRow("Read-only", yes(!w))) }
        let encrypted = (v["Encryption"] as? Bool ?? false) || (v["FileVault"] as? Bool ?? false)
        vol.append(InfoRow("Encrypted", yes(encrypted)))
        if v["Locked"] as? Bool == true { vol.append(InfoRow("Locked", "Yes")) }
        if let s = v["Sealed"] as? String, s != "No" { vol.append(InfoRow("Sealed", s)) }
        if let s = v["APFSContainerReference"] as? String { vol.append(InfoRow("APFS container", s)) }
        if let g = v["GlobalPermissionsEnabled"] as? Bool { vol.append(InfoRow("Ownership", g ? "Enabled" : "Ignored")) }
        if let n = v["VolumeAllocationBlockSize"] as? Int { vol.append(InfoRow("Allocation block", Util.bytes(n))) }

        var drive: [InfoRow] = []
        if !w.isEmpty {
            let model = (w["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? w["IORegistryEntryName"] as? String
            if let model { drive.append(InfoRow("Model", model)) }
            if let s = w["DeviceIdentifier"] as? String { drive.append(InfoRow("Device", s)) }
            if let s = w["BusProtocol"] as? String { drive.append(InfoRow("Bus", s)) }
            if let b = w["SolidState"] as? Bool { drive.append(InfoRow("Solid state", yes(b))) }
            if let b = w["RemovableMedia"] as? Bool { drive.append(InfoRow("Removable media", yes(b))) }
            if let n = w["Size"] as? Int { drive.append(InfoRow("Size", Util.bytes(n))) }
            if let n = w["DeviceBlockSize"] as? Int { drive.append(InfoRow("Block size", "\(n) bytes")) }
            if let s = w["Content"] as? String { drive.append(InfoRow("Partition map", schemeName(s))) }
            drive.append(InfoRow("SMART", w["SMARTStatus"] as? String ?? "Not Supported"))
        }

        let parts = ((list["AllDisksAndPartitions"] as? [[String: Any]])?.first?["Partitions"] as? [[String: Any]] ?? []).map { p in
            let name = (p["VolumeName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let fields = [name, p["Content"] as? String, (p["Size"] as? Int).map(Util.bytes), p["MountPoint"] as? String]
            return InfoRow(p["DeviceIdentifier"] as? String ?? "—", fields.compactMap { $0 }.joined(separator: " · "))
        }

        var out = [InfoSection(title: "Volume", rows: vol)]
        if !drive.isEmpty { out.append(InfoSection(title: "Drive", rows: drive)) }
        if !parts.isEmpty { out.append(InfoSection(title: "Partitions", rows: parts)) }
        let smart = smartRows(w["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as? [String: Any] ?? [:])
        if !smart.isEmpty { out.append(InfoSection(title: "SMART Details", rows: smart)) }
        return out
    }

    nonisolated static func schemeName(_ s: String) -> String {
        switch s {
        case "GUID_partition_scheme": "GUID (GPT)"
        case "FDisk_partition_scheme": "Master Boot Record (MBR)"
        case "Apple_partition_scheme": "Apple Partition Map"
        default: s
        }
    }

    /// NVMe health log fields as macOS passes them through. `_0` is the low 64 bits; the high half is zero in practice.
    nonisolated static func smartRows(_ k: [String: Any]) -> [InfoRow] {
        func int(_ key: String) -> Int? { k[key] as? Int }
        var out: [InfoRow] = []
        if let v = int("TEMPERATURE"), v > 0 { out.append(InfoRow("Temperature", "\(v - 273) °C")) }
        if let v = int("PERCENTAGE_USED") { out.append(InfoRow("Wear", "\(v)% of rated endurance used")) }
        if let v = int("AVAILABLE_SPARE") {
            out.append(InfoRow("Spare blocks", "\(v)%" + (int("AVAILABLE_SPARE_THRESHOLD").map { " (warns below \($0)%)" } ?? "")))
        }
        if let v = int("POWER_ON_HOURS_0") { out.append(InfoRow("Powered on", "\(v) hours")) }
        if let v = int("POWER_CYCLES_0") { out.append(InfoRow("Power cycles", "\(v)")) }
        if let v = int("UNSAFE_SHUTDOWNS_0") { out.append(InfoRow("Unsafe shutdowns", "\(v)")) }
        if let v = int("MEDIA_ERRORS_0") { out.append(InfoRow("Media errors", "\(v)")) }
        if let v = int("NUM_ERROR_INFO_LOG_ENTRIES_0") { out.append(InfoRow("Error log entries", "\(v)")) }
        // NVMe data units are 1000 × 512 bytes.
        if let v = int("DATA_UNITS_READ_0") { out.append(InfoRow("Data read", Util.bytes(v * 512_000))) }
        if let v = int("DATA_UNITS_WRITTEN_0") { out.append(InfoRow("Data written", Util.bytes(v * 512_000))) }
        return out
    }
}
