import XCTest
import CoreAudio
@testable import FastGlance

final class InspectorTests: XCTestCase {
    func testAudioDescriptions() {
        let rates = [AudioValueRange(mMinimum: 48000, mMaximum: 48000), AudioValueRange(mMinimum: 44100, mMaximum: 44100),
                     AudioValueRange(mMinimum: 48000, mMaximum: 48000), AudioValueRange(mMinimum: 8000, mMaximum: 192000)]
        XCTAssertEqual(AudioSource.rateList(rates), "8–192, 44.1, 48 kHz")
        XCTAssertEqual(AudioSource.formatName(bits: 24, flags: kAudioFormatFlagIsSignedInteger), "24-bit integer")
        XCTAssertEqual(AudioSource.formatName(bits: 32, flags: kAudioFormatFlagIsFloat), "32-bit float")
    }

    func testUSBDescriptors() {
        XCTAssertEqual(USBSource.bcd(0x0210), "2.10")
        XCTAssertEqual(USBSource.bcd(0x0320), "3.20")
        XCTAssertEqual(USBSource.className(3, 1, 1), "HID (boot keyboard) · 03/01/01")
        XCTAssertEqual(USBSource.className(0xFF, 0, 0), "Vendor specific · FF/00/00")
        XCTAssertEqual(USBSource.className(0, 0, 0), "Defined per interface")
        XCTAssertEqual(USBSource.className(0x42, 0, 0), "Class 0x42 · 42/00/00")
    }

    func testFourCC() {
        XCTAssertEqual(CameraSource.fourCC(0x3432_3076), "420v")
        XCTAssertEqual(CameraSource.fourCC(0x7573_6220), "usb")
        XCTAssertEqual(CameraSource.fourCC(0x0000_0001), "0x00000001")
    }

    func testLsofAndVerifySummary() {
        XCTAssertEqual(DiskSource.lsofCommands("p412\ncPreview\np9\ncFinder\np413\ncPreview\n"), ["Finder", "Preview"])
        XCTAssertEqual(DiskSource.lsofCommands(""), [])
        let exfat = """
        Started file system verification on disk8s1 (FGexFAT)
        Verifying file system
        Volume was successfully unmounted
        Performing fsck_exfat -n -x /dev/rdisk8s1
        Checking volume
        Checking main boot region
        Volume name is FGexFAT
        Rechecking alternate boot region
        The volume FGexFAT appears to be OK
        File system check exit code is 0
        Restoring the original state found as mounted
        Finished file system verification on disk8s1 (FGexFAT)
        """
        XCTAssertEqual(DiskSource.verifySummary(exfat), "The volume FGexFAT appears to be OK")
        let apfs = """
        Checking the fsroot tree
        The volume FGapfs was formatted by newfs_apfs (2332.140.13.702.2) and last modified by apfs_kext (2332.140.13.702.2)
        The volume /dev/rdisk10s1 with UUID 5D6A3BE6 appears to be OK
        Restoring the original state found as mounted
        """
        XCTAssertEqual(DiskSource.verifySummary(apfs), "The volume /dev/rdisk10s1 with UUID 5D6A3BE6 appears to be OK")
        XCTAssertEqual(DiskSource.lastLine("Unmount of disk8s1 failed: at least one volume could not be unmounted\n"),
                       "Unmount of disk8s1 failed: at least one volume could not be unmounted")
    }

    func testDiskDescription() {
        let vol: [String: Any] = ["DeviceIdentifier": "disk8s1", "FilesystemUserVisibleName": "ExFAT", "MountPoint": "/Volumes/FGexFAT",
                                  "WritableVolume": true, "GlobalPermissionsEnabled": false, "VolumeAllocationBlockSize": 512,
                                  "ParentWholeDisk": "disk8", "SMARTStatus": "Not Supported"]
        let whole: [String: Any] = ["DeviceIdentifier": "disk8", "MediaName": "", "IORegistryEntryName": "Untitled 1",
                                    "BusProtocol": "USB", "RemovableMedia": true, "Size": 209715200, "DeviceBlockSize": 512,
                                    "Content": "FDisk_partition_scheme", "SMARTStatus": "Not Supported"]
        let list: [String: Any] = ["AllDisksAndPartitions": [["DeviceIdentifier": "disk8", "Partitions": [
            ["DeviceIdentifier": "disk8s1", "VolumeName": "FGexFAT", "Content": "Windows_NTFS", "Size": 209714688, "MountPoint": "/Volumes/FGexFAT"]]]]]
        let s = DiskSource.describe(volume: vol, whole: whole, list: list)
        XCTAssertEqual(s.map(\.title), ["Volume", "Drive", "Partitions"])
        let volume = Dictionary(uniqueKeysWithValues: s[0].rows.map { ($0.key, $0.value) })
        XCTAssertEqual(volume["Read-only"], "No")
        XCTAssertEqual(volume["Encrypted"], "No")
        XCTAssertEqual(volume["Ownership"], "Ignored")
        let drive = Dictionary(uniqueKeysWithValues: s[1].rows.map { ($0.key, $0.value) })
        XCTAssertEqual(drive["Model"], "Untitled 1")
        XCTAssertEqual(drive["Partition map"], "Master Boot Record (MBR)")
        XCTAssertEqual(drive["SMART"], "Not Supported")
        XCTAssertTrue(s[2].rows[0].value.hasPrefix("FGexFAT · Windows_NTFS · "))

        XCTAssertEqual(DiskSource.health(whole).text, "Not reported by this drive")
        let nvme: [String: Any] = ["SMARTStatus": "Verified", "SMARTDeviceSpecificKeysMayVaryNotGuaranteed":
                                    ["TEMPERATURE": 308, "PERCENTAGE_USED": 3, "AVAILABLE_SPARE": 100, "AVAILABLE_SPARE_THRESHOLD": 99,
                                     "POWER_ON_HOURS_0": 275, "MEDIA_ERRORS_0": 0, "DATA_UNITS_WRITTEN_0": 2]]
        XCTAssertEqual(DiskSource.health(nvme).text, "SMART verified · 3% worn")
        XCTAssertTrue(DiskSource.health(["SMARTStatus": "Failing"]).failing)
        let smart = Dictionary(uniqueKeysWithValues: DiskSource.smartRows(nvme["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] as! [String: Any])
            .map { ($0.key, $0.value) })
        XCTAssertEqual(smart["Temperature"], "35 °C")
        XCTAssertEqual(smart["Spare blocks"], "100% (warns below 99%)")
        XCTAssertEqual(smart["Data written"], Util.bytes(1_024_000))
    }
}

final class PrinterInspectorTests: XCTestCase {
    func testJobsAndReasons() {
        // Real ipptool -tv output: attribute order differs per job, so jobs split where a key repeats.
        let text = """
                job-originating-user-name (nameWithoutLanguage) = mlayklayer
                job-name (nameWithoutLanguage) = FG held test
                time-at-creation (integer) = 1792488569
                job-id (integer) = 272
                job-state (enum) = pending-held
                job-state-reasons (keyword) = job-hold-until-specified
                job-k-octets (integer) = 1
                job-originating-user-name (nameWithoutLanguage) = mlayklayer
                job-name (nameWithoutLanguage) = FG pending test
                time-at-creation (integer) = 1792488569
                job-id (integer) = 273
                job-state (enum) = processing
                job-state-reasons (keyword) = job-printing
                job-k-octets (integer) = 1
        """
        let jobs = PrinterSource.parseJobs(text)
        XCTAssertEqual(jobs.map(\.id), [272, 273])
        XCTAssertEqual(jobs[0].name, "FG held test")
        XCTAssertTrue(jobs[0].isHeld)
        XCTAssertEqual(jobs[1].state, "processing")
        XCTAssertEqual(PrinterSource.parseJobs(""), [])

        let r = PrinterSource.reasons("media-jam-error,toner-low-warning,offline-report,paused,none")
        XCTAssertEqual(r.map(\.text), ["Paper jam", "Toner low (warning)", "Printer reports offline", "Paused"])
        XCTAssertEqual(r.map(\.isError), [true, false, false, false])
        XCTAssertEqual(PrinterSource.reasons("none"), [])
        XCTAssertEqual(PrinterSource.reasons("weird-thing-error").first?.text, "Weird Thing")
    }

    func testCapabilities() {
        XCTAssertEqual(PrinterSource.mediaName("iso_a4_210x297mm"), "A4")
        XCTAssertEqual(PrinterSource.mediaName("na_letter_8.5x11in"), "Letter")
        XCTAssertEqual(PrinterSource.mediaName("jis_b5_182x257mm"), "JIS B5")
        XCTAssertEqual(PrinterSource.mediaName("na_executive_7.25x10.5in"), "Executive")
        XCTAssertEqual(PrinterSource.mediaName("odd"), "odd")
        let s = PrinterSource.sections(["media-supported": "iso_a4_210x297mm,na_legal_8.5x14in", "sides-supported": "one-sided",
                                        "print-color-mode-supported": "monochrome", "marker-names": "Black", "marker-levels": "97",
                                        "marker-types": "toner", "printer-state": "idle", "printer-state-reasons": "none"])
        let caps = Dictionary(uniqueKeysWithValues: s[0].rows.map { ($0.key, $0.value) })
        XCTAssertEqual(caps["Paper sizes"], "A4, Legal")
        XCTAssertEqual(caps["Sides"], "One-sided")
        XCTAssertEqual(caps["Color"], "Black & white")
        XCTAssertEqual(s[1].rows.first?.value, "97% · Toner")
    }
}

final class NetworkInspectorTests: XCTestCase {
    func testPing() {
        XCTAssertEqual(NetTools.pingSample("64 bytes from 172.20.10.1: icmp_seq=0 ttl=64 time=4.567 ms"), .reply(4.567))
        XCTAssertEqual(NetTools.pingSample("Request timeout for icmp_seq 3"), .lost)
        XCTAssertNil(NetTools.pingSample("PING 172.20.10.1 (172.20.10.1): 56 data bytes"))
        let s = NetTools.stats([.reply(10), .reply(14), .lost, .reply(12)])
        XCTAssertEqual(s.average, 12)
        XCTAssertEqual(s.jitter, 3)  // |14-10| and |12-14|
        XCTAssertEqual(s.loss, 0.25)
        XCTAssertEqual(NetTools.stats([]).loss, 0)
    }

    func testDNSDigSMB() {
        let scutil = """
        DNS configuration

        resolver #1
          search domain[0] : lan
          nameserver[0] : 172.20.10.1
          nameserver[1] : fe80::1%en0
          if_index : 11 (en0)

        resolver #2
          domain   : local
          nameserver[0] : 224.0.0.251

        DNS configuration (for scoped queries)

        resolver #1
          nameserver[0] : 9.9.9.9
        """
        let d = NetTools.dns(scutil)
        XCTAssertEqual(d.servers, ["172.20.10.1", "fe80::1%en0"])
        XCTAssertEqual(d.domains, ["lan"])
        XCTAssertEqual(NetTools.digQueryTime(";; Query time: 23 msec\n;; SERVER: 172.20.10.1#53"), 23)
        XCTAssertNil(NetTools.digQueryTime(";; connection timed out; no servers could be reached"))

        let smb = """
        Share                                           Type    Comments
        -------------------------------
        Public                                          Disk
        Time Machine Backups                            Disk    Backups here
        IPC$                                            Pipe    Remote IPC

        3 shares listed
        """
        XCTAssertEqual(NetTools.smbShares(smb), [
            NetTools.Share(name: "Public", type: "Disk", comment: ""),
            NetTools.Share(name: "Time Machine Backups", type: "Disk", comment: "Backups here"),
            NetTools.Share(name: "IPC$", type: "Pipe", comment: "Remote IPC"),
        ])
        XCTAssertEqual(NetTools.channelCounts([(6, "2.4 GHz"), (6, "2.4 GHz"), (36, "5 GHz")]), ["2.4 GHz/6": 2, "5 GHz/36": 1])
        // Length-prefixed TXT strings: "model=J105aAP", a bare "flag", a binary value.
        var txt = Data([13]) + Data("model=J105aAP".utf8)
        txt += Data([4]) + Data("flag".utf8)
        txt += Data([6]) + Data("bin=".utf8) + Data([0x01, 0x02])
        XCTAssertEqual(NetworkSource.txtText(txt), "bin=<2 bytes>, flag, model=J105aAP")
        XCTAssertEqual(NetworkSource.txtText(Data([0])), "")
        XCTAssertEqual(NetworkSource.txtText(Data([9]) + Data("short".utf8)), "short")  // truncated record
    }

    func testDisplayPanelFacts() {
        // MacBook Air 13" (M3): 2560 px across 290 mm is 224 ppi.
        XCTAssertEqual(DisplaySource.ppi(pixels: 2560, mm: 290)!, 224, accuracy: 0.5)
        XCTAssertNil(DisplaySource.ppi(pixels: 1920, mm: 0))  // projectors and some adapters report no size
        XCTAssertEqual(DisplaySource.edrText(potential: 1), "None (SDR only)")
        XCTAssertEqual(DisplaySource.edrText(potential: 16), "Up to 16.0× SDR white")
    }
}
