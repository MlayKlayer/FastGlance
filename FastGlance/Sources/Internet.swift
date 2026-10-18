import CoreWLAN
import CoreLocation
import Network
import Darwin

/// How this Mac reaches the internet right now: Wi-Fi, Ethernet or an iPhone's Personal Hotspot.
@MainActor final class InternetSource: NSObject, DeviceSource, CLLocationManagerDelegate {
    let prefix = "inet"
    var onChange: (() -> Void)?
    private(set) var devices: [Device] = []

    private let monitor = NWPathMonitor()
    private var path: NWPath?
    private let location = CLLocationManager()
    private(set) var gateway: String?
    private var gatewayMAC: String?
    private var gatewayKnown = false
    private var hotspotStart: (iface: String, bytes: UInt64)?

    func start() {
        location.delegate = self
        // macOS only reveals Wi-Fi names (SSIDs) to apps with location access.
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            DispatchQueue.main.async {
                self.path = p
                self.refreshGateway()
            }
        }
        monitor.start(queue: .global(qos: .utility))
        _ = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.rebuild() } }
        _ = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshGateway() } }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { rebuild() }
    }

    private func refreshGateway() {
        DispatchQueue.global(qos: .utility).async {
            let gw = NetworkSource.parseGateway(Util.text("/sbin/route", ["-n", "get", "default"]))
            let mac = gw.flatMap { NetworkSource.parseARP(Util.text("/usr/sbin/arp", ["-n", $0]))[$0] }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The MAC is the row's id; a missed ARP lookup on the same router mustn't turn it into a new device.
                    self.gatewayMAC = mac ?? (gw == self.gateway ? self.gatewayMAC : nil)
                    self.gateway = gw
                    self.gatewayKnown = true
                    self.rebuild()
                }
            }
        }
    }

    private func rebuild() {
        let next = gatewayKnown ? current().map { [$0] } ?? [] : devices
        if next != devices { devices = next; onChange?() }
    }

    private func current() -> Device? {
        guard let path, path.status == .satisfied else { hotspotStart = nil; return nil }
        let wifi = CWWiFiClient.shared().interface()
        let usesWiFi = path.usesInterfaceType(.wifi)
        let usesEthernet = path.usesInterfaceType(.wiredEthernet)
        let iface = path.availableInterfaces.first { path.usesInterfaceType($0.type) }?.name
        // macOS marks an iPhone's Personal Hotspot as an "expensive" (metered) Wi-Fi network.
        let hotspot = usesWiFi && path.isExpensive
        let ssid = usesWiFi ? wifi?.ssid() : nil
        let canSeeSSID = [.authorizedAlways, .authorized].contains(location.authorizationStatus)

        let name = ssid ?? (hotspot ? "iPhone Hotspot" : usesWiFi ? "Wi-Fi" : usesEthernet ? "Ethernet" : "Internet")
        let medium = hotspot ? "Personal Hotspot" : usesWiFi ? "Wi-Fi" : usesEthernet ? "Ethernet" : "Network"

        var status = [medium]
        var info = [InfoRow("Connection", medium)]
        if let iface {
            info.append(InfoRow("Interface", iface))
            if let ip = Self.ipv4(of: iface) { info.append(InfoRow("This Mac's IP", ip)) }
        }
        if let gateway { info.append(InfoRow(hotspot ? "iPhone's IP" : "Router IP", gateway)) }
        if let gatewayMAC { info.append(InfoRow(hotspot ? "iPhone's MAC" : "Router MAC", gatewayMAC.uppercased())) }

        if usesWiFi, let wifi {
            info.append(InfoRow("Network name", ssid ?? (canSeeSSID ? "—" : "Hidden — allow Location for FastGlance")))
            let rssi = wifi.rssiValue()
            if rssi != 0 {
                status.append(Self.signalWord(rssi))
                info.append(InfoRow("Signal", "\(rssi) dBm (\(Self.signalWord(rssi).lowercased())), noise \(wifi.noiseMeasurement()) dBm"))
            }
            if let ch = wifi.wlanChannel() {
                info.append(InfoRow("Band", "\(Self.bandName(ch.channelBand)) · channel \(ch.channelNumber)"))
            }
            if wifi.transmitRate() > 0 { info.append(InfoRow("Link rate", "\(Int(wifi.transmitRate())) Mb/s")) }
            info.append(InfoRow("Security", Self.securityName(wifi.security())))
        }

        if hotspot, let iface, let total = Self.interfaceBytes(iface) {
            if hotspotStart?.iface != iface { hotspotStart = (iface, total) }
            let used = total &- (hotspotStart?.bytes ?? total)
            status.append("\(Util.bytes(Int(used))) used")
            info.append(InfoRow("Data this session", Util.bytes(Int(used))))
        } else {
            hotspotStart = nil
        }
        if path.isConstrained {
            status.append("Low Data Mode")
            info.append(InfoRow("Low Data Mode", "On"))
        }
        info.append(InfoRow("Metered", path.isExpensive ? "Yes" : "No"))

        // Stable per network and independent of location access: the router's (or iPhone's) hardware address.
        let key = gatewayMAC ?? ssid ?? name
        return Device(id: "inet:\(key)", name: name, kind: .internet, isConnected: true,
                      status: status.joined(separator: " · "), info: info,
                      symbol: hotspot ? "personalhotspot" : usesWiFi ? "wifi" : "network")
    }

    func actions(for device: Device) -> [DeviceAction] {
        guard device.isConnected else { return [] }
        let hotspot = device.icon == "personalhotspot"
        var out: [DeviceAction] = []
        if let gateway, !hotspot {
            out.append(DeviceAction(device, "router", "Open Router Page", "safari") { Util.open("http://\(gateway)") })
        }
        if let gateway {
            out.append(DeviceAction(device, "ping", hotspot ? "Ping iPhone" : "Ping Router", "waveform.path.ecg") {
                NetworkSource.ping(gateway, device)
            })
        }
        if device.icon != "network" {
            out.append(DeviceAction(device, "disconnect", hotspot ? "Disconnect from Hotspot" : "Disconnect Wi-Fi", "wifi.slash") {
                CWWiFiClient.shared().interface()?.disassociate()
            })
        }
        if ![.authorizedAlways, .authorized].contains(location.authorizationStatus) {
            out.append(DeviceAction(device, "location", "Show Network Name…", "location") {
                Util.open("x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
            })
        }
        out.append(DeviceAction(device, "settings", "Network Settings…", "gearshape") {
            Util.open("x-apple.systempreferences:com.apple.Network-Settings.extension")
        })
        return out
    }

    // MARK: - Helpers

    nonisolated static func signalWord(_ rssi: Int) -> String {
        switch rssi {
        case (-55)...: "Excellent"
        case (-67)...: "Good"
        case (-75)...: "Fair"
        default: "Weak"
        }
    }

    nonisolated static func bandName(_ b: CWChannelBand) -> String {
        switch b {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: "Unknown band"
        }
    }

    nonisolated static func securityName(_ s: CWSecurity) -> String {
        switch s {
        case .none: "None (open network)"
        case .WEP: "WEP (insecure)"
        case .wpaPersonal, .wpaPersonalMixed: "WPA Personal"
        case .wpa2Personal: "WPA2 Personal"
        case .wpa3Personal: "WPA3 Personal"
        case .wpa3Transition: "WPA2/WPA3 Personal"
        case .wpa2Enterprise, .wpaEnterprise, .wpaEnterpriseMixed, .wpa3Enterprise: "Enterprise"
        default: "Other"
        }
    }

    nonisolated static func ipv4(of iface: String) -> String? {
        NetworkSource.interfaceIPv4s().first { $0.iface == iface }?.ip
    }

    /// 64-bit in+out byte counters for one interface (getifaddrs only has 32-bit ones that wrap at 4 GB).
    nonisolated static func interfaceBytes(_ iface: String) -> UInt64? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }
        let index = if_nametoindex(iface)
        return buf.withUnsafeBytes { raw -> UInt64? in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard hdr.ifm_msglen > 0 else { return nil }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let m = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if UInt32(m.ifm_index) == index { return m.ifm_data.ifi_ibytes + m.ifm_data.ifi_obytes }
                }
                offset += Int(hdr.ifm_msglen)
            }
            return nil
        }
    }
}
