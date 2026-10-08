import Testing
@testable import ActivityCore

@Suite("USB link")
struct USBLinkTests {
    @Test func usb3DeviceAtHighSpeedIsSlow() {
        #expect(USBLinkCheck.isSlow(bcdUSB: 0x0320, deviceSpeed: 2))
        #expect(!USBLinkCheck.isSlow(bcdUSB: 0x0320, deviceSpeed: 3))
        // A USB 2 device at USB 2 speed is exactly what it can do; so is the USB 2 half of a USB 3 hub.
        #expect(!USBLinkCheck.isSlow(bcdUSB: 0x0210, deviceSpeed: 2))
    }

    @Test func readableNames() {
        #expect(USBLinkCheck.describe(bcdUSB: 0x0320) == "USB 3.2")
        #expect(USBLinkCheck.describe(speed: 2) == "USB 2 · 480 Mbit/s")
    }
}
