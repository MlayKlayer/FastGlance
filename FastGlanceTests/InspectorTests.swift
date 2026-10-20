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
}
