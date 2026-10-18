import AppKit

@MainActor final class DiskSource: DeviceSource {
    let prefix = "disk"
    var onChange: (() -> Void)?
    private(set) var devices: [Device] = []
    private var urls: [String: URL] = [:]
    private var localIDs: Set<String> = []

    private let keys: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsInternalKey, .volumeIsEjectableKey,
                                          .volumeIsRemovableKey, .volumeIsLocalKey, .volumeTotalCapacityKey,
                                          .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey]

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        }
        reload()
    }

    func reload() {
        var next: [Device] = []
        var nextURLs: [String: URL] = [:]
        var nextLocal: Set<String> = []
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
            let doctor = USBDoctor.bsdName(forVolume: url).flatMap(USBDoctor.report(bsdName:))
            var extra: [InfoRow] = []
            if let doctor {
                extra.append(InfoRow("Connection", doctor.link))
                if !doctor.via.isEmpty { extra.append(InfoRow("Through", doctor.via.joined(separator: " → "))) }
                if let note = doctor.note { extra.append(InfoRow("Note", note)) }
            }
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
                warning: doctor?.warning))
        }
        urls = nextURLs
        localIDs = nextLocal
        if next != devices { devices = next; onChange?() }
    }

    /// 0...1 used fraction, for the capacity bar.
    func usage(_ device: Device) -> Double? {
        guard let url = urls[device.id], let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = v.volumeTotalCapacity, total > 0, let free = v.volumeAvailableCapacity else { return nil }
        return 1 - Double(free) / Double(total)
    }

    func actions(for device: Device) -> [DeviceAction] {
        guard let url = urls[device.id] else { return [] }
        return [
            DeviceAction(device, "eject", "Eject", "eject") { [weak self] in self?.eject(url, name: device.name) },
            DeviceAction(device, "open", "Open in Finder", "folder") { NSWorkspace.shared.open(url) },
            DeviceAction(device, "copypath", "Copy Path", "doc.on.doc") { Util.copy(url.path) },
        ]
    }

    var hasEjectable: Bool { !urls.isEmpty }

    /// Mounted external volumes on this Mac (not network shares), for unmounting before sleep.
    var localVolumes: [(url: URL, name: String, uuid: String?)] {
        devices.compactMap { d in
            guard localIDs.contains(d.id), let url = urls[d.id] else { return nil }
            let uuid = d.raw.first { $0.key == "UUID" }?.value
            return (url, d.name, uuid == "—" ? nil : uuid)
        }
    }

    func ejectAll() {
        for d in devices { if let url = urls[d.id] { eject(url, name: d.name) } }
    }

    private func eject(_ url: URL, name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                DispatchQueue.main.async {
                    Notifier.shared.post("Couldn't eject \(name)", error.localizedDescription)
                }
            }
        }
    }
}
