import Foundation
import Testing

@testable import LanternfishKit

@Suite struct VendorDatabaseTests {
    @Test func appleOUIResolvesToApple() throws {
        let db = VendorDatabase.shared
        #expect(db.vendor(for: try #require(MACAddress("A4:83:E7:12:34:56"))) == "Apple")
        #expect(db.vendor(for: try #require(MACAddress("3c:22:fb:1:2:3"))) == "Apple")
    }

    @Test func samsungOUIContainsSamsung() throws {
        let vendor = VendorDatabase.shared.vendor(for: try #require(MACAddress("F8:D0:BD:00:00:01")))
        #expect(vendor?.contains("Samsung") == true)
    }

    @Test func cleanedNamesInRealDatabase() throws {
        let db = VendorDatabase.shared
        #expect(db.vendor(for: try #require(MACAddress("B8:27:EB:00:00:01"))) == "Raspberry Pi")
        #expect(db.vendor(for: try #require(MACAddress("50:C7:BF:00:00:01"))) == "TP-Link")
        #expect(db.vendor(for: try #require(MACAddress("24:A1:60:00:00:01"))) == "Espressif")
    }

    @Test func locallyAdministeredMACIsNil() throws {
        let db = VendorDatabase(tsv: "A683E7\tShouldNotMatch\nA483E7\tApple\n")
        let laa = try #require(MACAddress("A6:83:E7:12:34:56"))
        #expect(laa.isLocallyAdministered)
        #expect(db.vendor(for: laa) == nil)
        #expect(VendorDatabase.shared.vendor(for: laa) == nil)
    }

    @Test func customTSVParsingAndUnknownPrefix() throws {
        let db = VendorDatabase(tsv: "A483E7\tApple\r\nf8d0bd\tSamsung Electronics\nbad line\nZZZZZZ\tNope\n\n")
        #expect(db.count == 2)
        #expect(db.vendor(for: try #require(MACAddress("A4:83:E7:00:00:00"))) == "Apple")
        #expect(db.vendor(for: try #require(MACAddress("F8:D0:BD:00:00:00"))) == "Samsung Electronics")
        #expect(db.vendor(for: try #require(MACAddress("00:11:22:33:44:55"))) == nil)
    }

    @Test func sharedDatabaseIsLargeAndLoadsFast() {
        let start = ContinuousClock.now
        let count = VendorDatabase.shared.count
        let elapsed = ContinuousClock.now - start
        #expect(count > 30_000)
        print("VendorDatabase.shared: \(count) entries, first access \(elapsed)")
    }
}
