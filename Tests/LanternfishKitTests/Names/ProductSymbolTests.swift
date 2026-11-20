import AppKit
import Testing

@testable import LanternfishKit

@Suite struct ProductSymbolTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var label: String
        var name: String? = nil
        var hostname: String? = nil
        var model: String? = nil
        var manufacturer: String? = nil
        var vendor: String? = nil
        var services: Set<String> = []
        var osHint: String? = nil
        var webTitle: String? = nil
        var kind: DeviceKind = .unknown
        var customKind: DeviceKind? = nil
        var expected: String?
        var testDescription: String { label }

        var device: Device {
            var d = Device(ip: IPv4Address("192.168.1.50")!)
            d.name = name
            d.hostname = hostname
            d.model = model
            d.manufacturer = manufacturer
            d.vendor = vendor
            d.services = services
            d.osHint = osHint
            d.webTitle = webTitle
            d.kind = kind
            d.customKind = customKind
            return d
        }
    }

    static let cases: [Case] = [
        // Apple, as Bonjour reports it (friendly model names) and as raw identifiers.
        Case(
            label: "HomePod (friendly model)", name: "Woonkamer", model: "HomePod", manufacturer: "Apple",
            services: ["AirPlay", "AirPlay Audio"], kind: .speaker, expected: "homepod"),
        Case(
            label: "HomePod mini (raw identifier)", model: "AudioAccessory5,1", kind: .speaker, expected: "homepod.mini"
        ),
        Case(
            label: "HomePod mini (by name)", name: "HomePod mini Keuken", model: "HomePod", kind: .speaker,
            expected: "homepod.mini"),
        Case(label: "HomePod 2 (raw identifier)", model: "AudioAccessory6,1", kind: .speaker, expected: "homepod"),
        Case(
            label: "Apple TV (raw)", name: "Living Room", model: "AppleTV11,1", services: ["AirPlay"], kind: .tv,
            expected: "appletv"),
        Case(label: "Apple TV (friendly)", model: "Apple TV", kind: .tv, expected: "appletv"),
        Case(label: "Mac mini (raw)", model: "Macmini9,1", kind: .computer, expected: "macmini"),
        Case(label: "Mac mini (Apple silicon id)", model: "Mac14,3", kind: .computer, expected: "macmini"),
        Case(label: "Mac Studio", model: "Mac Studio", kind: .computer, expected: "macstudio"),
        Case(label: "Mac Pro 2019", model: "MacPro7,1", kind: .computer, expected: "macpro.gen3"),
        Case(label: "Mac Pro 2013", model: "MacPro6,1", kind: .computer, expected: "macpro.gen2"),
        Case(label: "iMac", model: "iMac21,1", kind: .computer, expected: "desktopcomputer"),
        Case(
            label: "MacBook Pro", name: "MacBook Pro van Sam", hostname: "MacBook-Pro-van-Sam.local",
            model: "MacBook Pro", manufacturer: "Apple", vendor: "Foxconn", kind: .computer, expected: "laptopcomputer"),
        Case(label: "MacBook by hostname only", hostname: "MacBookPro", kind: .computer, expected: "laptopcomputer"),
        Case(
            label: "iPhone", hostname: "iPhone-van-alex.local", model: "iPhone", manufacturer: "Apple",
            services: ["Apple Device"], kind: .phone, expected: "iphone"),
        Case(label: "iPhone by hostname", hostname: "iPhonevanAlex.home", kind: .phone, expected: "iphone"),
        Case(
            label: "iPad", name: "iPad van Alex", model: "iPad", manufacturer: "Apple", kind: .tablet,
            expected: "ipad"),
        Case(
            label: "Apple Watch", hostname: "Watch.home", model: "Apple Watch", manufacturer: "Apple", kind: .phone,
            expected: "applewatch"),
        Case(label: "Vision Pro", model: "RealityDevice14,1", expected: "visionpro"),
        Case(
            label: "AirPort Extreme", name: "Base Station", services: ["AirPort Base Station"], kind: .router,
            expected: "airport.extreme"),
        Case(
            label: "AirPort Express", name: "AirPort Express", services: ["AirPort Base Station"], kind: .router,
            expected: "airport.express"),
        Case(
            label: "Ambiguous iPhone or iPad", model: "iPhone or iPad", manufacturer: "Apple", kind: .phone,
            expected: nil),

        // Consoles and streaming
        Case(
            label: "PS5", name: "SpZc-F47D9B", hostname: "PS5-F47D9B.local", model: "PS5", manufacturer: "Sony",
            vendor: "Sony PlayStation", services: ["Spotify Connect"], kind: .gameConsole, expected: "playstation.logo"),
        Case(
            label: "Xbox", hostname: "XboxOne", model: "Xbox", manufacturer: "Microsoft", kind: .gameConsole,
            expected: "xbox.logo"),
        Case(
            label: "Chromecast", name: "Slaapkamer", model: "Chromecast", manufacturer: "Google",
            services: ["Chromecast"], kind: .tv, expected: "mediastick"),
        Case(
            label: "Sony TV with Chromecast built in stays a TV", name: "SONY KD-55A8", hostname: "Android.local",
            model: "KD-55A8", manufacturer: "Sony", vendor: "WNC",
            services: ["AirPlay", "Android TV", "Chromecast", "HomeKit", "Spotify Connect", "UPnP"], kind: .tv,
            expected: nil),
        Case(
            label: "NVIDIA Shield", model: "Shield TV", manufacturer: "NVIDIA", kind: .tv, expected: "tv.and.mediabox"),

        // Speakers
        Case(
            label: "Sonos", name: "Keuken", model: "Sonos One", vendor: "Sonos", services: ["Sonos", "AirPlay"],
            kind: .speaker, expected: "hifispeaker.2"),

        // Smart home
        Case(
            label: "IKEA DIRIGERA", name: "DIRIGERA", hostname: "gw2-365a9045cfa4.local",
            model: "DIRIGERA Hub for smart products", manufacturer: "IKEA", vendor: "IKEA of Sweden",
            services: ["HomeKit", "Thread", "Thread Border Router"], kind: .iot, expected: "homekit"),
        Case(
            label: "Philips Hue Bridge", name: "Philips Hue - 1A2B3C", model: "Hue Bridge", manufacturer: "Philips Hue",
            services: ["Philips Hue", "HomeKit"], kind: .iot, expected: "lightbulb.led.fill"),
        Case(label: "WLED", name: "wled-kitchen", services: ["WLED"], kind: .iot, expected: "light.strip.2"),
        Case(
            label: "Toon thermostat", hostname: "qb-659916001600-1815A03VJJ", model: "Toon thermostat",
            manufacturer: "Quby", vendor: "Murata", osHint: "Embedded Linux", webTitle: "Z-Wave advanced", kind: .iot,
            expected: "thermometer.medium"),
        Case(label: "Roborock", hostname: "roborock-vacuum-a15", kind: .iot, expected: "robotic.vacuum"),
        Case(
            label: "ESPHome sensor", name: "sensor-display-receiver", hostname: "sensor-display-receiver.local",
            model: "ESP32-S3", manufacturer: "Espressif", vendor: "Espressif", services: ["ESPHome"],
            osHint: "ESPHome 2025.4.1", kind: .iot, expected: "sensor.fill"),
        Case(
            label: "Air quality monitor on an ESP32", hostname: "esp32-139E84.home", model: "ESP32",
            manufacturer: "Espressif", vendor: "Espressif", webTitle: "ZPHS01B Air Quality", kind: .iot,
            expected: "sensor.fill"),
        Case(label: "Plain ESPHome node", name: "garage-door", services: ["ESPHome"], kind: .iot, expected: "cpu"),
        Case(
            label: "Video doorbell", name: "Ring Video Doorbell", manufacturer: "Ring", kind: .camera,
            expected: "video.doorbell"),
        Case(
            label: "Tuya smart device stays generic", model: "Smart device", manufacturer: "Tuya", vendor: "Tuya",
            kind: .iot, expected: nil),

        // Printers
        Case(
            label: "Bambu Lab P2S", name: "printer", model: "P2S 3D Printer", manufacturer: "Bambu Lab",
            vendor: "Quectel Wireless Solutions", services: ["Bambu Lab"], osHint: "Bambu firmware 01.03.00.00",
            kind: .printer, expected: "cube.fill"),
        Case(
            label: "Kyocera printer", name: "Kyocera ECOSYS M6026cidn", hostname: "Printer.local",
            model: "Kyocera ECOSYS M6026cidn", manufacturer: "Kyocera", vendor: "Kyocera Display",
            services: ["Printer", "Web"], kind: .printer, expected: "printer.fill"),

        // NAS and computers
        Case(
            label: "TrueNAS", name: "truenas", hostname: "truenas.local",
            services: ["File Sharing (SMB)", "Time Machine", "Web"], osHint: "TrueNAS", webTitle: "TrueNAS", kind: .nas,
            expected: "server.rack"),
        Case(
            label: "Synology DiskStation", model: "DS920+", manufacturer: "Synology", kind: .nas,
            expected: "externaldrive.fill"),
        Case(
            label: "Raspberry Pi", hostname: "raspberrypi.local", vendor: "Raspberry Pi Trading", kind: .computer,
            expected: "cpu"),
        Case(
            label: "Windows PC", name: "DESKTOP-4FJ2K", model: "Windows PC", osHint: "Windows", kind: .computer,
            expected: "pc"),
        Case(
            label: "Ubuntu box stays generic", hostname: "ubuntu.home", vendor: "NetApp", osHint: "Ubuntu 24.04",
            webTitle: "Coolify", kind: .computer, expected: nil),

        // Phones and wearables
        Case(
            label: "Samsung Galaxy", hostname: "Galaxy-XCover-5", model: "Galaxy", manufacturer: "Samsung",
            kind: .phone,
            expected: "smartphone"),
        Case(label: "Garmin watch", vendor: "Garmin", kind: .phone, expected: "watch.analog"),

        // Routers stay on the kind symbol.
        Case(
            label: "Zyxel router", hostname: "router.asus.com", model: "NR7101", manufacturer: "Zyxel",
            vendor: "Zyxel Communications", webTitle: "Zyxel", kind: .router, expected: nil),

        // Weak brand-only evidence never names a product.
        Case(label: "Garmin OUI of unknown kind", vendor: "Garmin", expected: nil),
        Case(label: "Samsung OUI of unknown kind", vendor: "Samsung Electronics", expected: nil),
        Case(label: "HP OUI on a computer", vendor: "Hewlett Packard", kind: .computer, expected: nil),

        // Unknown kind accepts a clear product.
        Case(label: "Unclassified HomePod", model: "AudioAccessory1,1", expected: "homepod"),

        // The user's type wins.
        Case(
            label: "Apple TV the user calls a computer", model: "AppleTV11,1", kind: .tv, customKind: .computer,
            expected: nil),
        Case(
            label: "Custom kind agreeing with the product", model: "AppleTV11,1", customKind: .tv, expected: "appletv"),
        Case(
            label: "Custom unknown overrides", model: "Macmini9,1", kind: .computer, customKind: .unknown, expected: nil
        ),
        Case(
            label: "ESPHome node the user calls a camera", services: ["ESPHome"], kind: .iot,
            customKind: .camera, expected: nil),
    ]

    @Test(arguments: cases)
    func mapping(_ c: Case) {
        #expect(ProductSymbol.symbol(for: c.device) == c.expected)
    }

    @Test func matchCarriesLabelAndKind() throws {
        var d = Device(ip: IPv4Address("10.0.0.2")!)
        d.model = "AppleTV11,1"
        let m = try #require(ProductSymbol.match(for: d))
        #expect(m == .init(symbol: "appletv", label: "Apple TV", kind: .tv))
        d.model = "MacBook Air"
        d.kind = .computer
        #expect(ProductSymbol.match(for: d)?.label == "MacBook Air")
    }

    /// Every case's symbol is in the pinned set.
    @Test func casesUsePinnedSymbols() {
        for c in Self.cases {
            if let s = c.expected { #expect(ProductSymbol.allSymbols.contains(s), "\(s)") }
        }
    }

    /// Every symbol the mapping can return exists in this SDK.
    @Test func allSymbolsExist() {
        for name in ProductSymbol.allSymbols.sorted() {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing SF Symbol \(name)")
        }
    }

    // MARK: - Monograms

    @Test(arguments: [
        ("Sonos", "S"),
        ("Hewlett Packard", "HP"),
        ("Hewlett Packard Enterprise", "HP"),
        ("HP Inc.", "HP"),
        ("LG Electronics", "LG"),
        ("TP-Link", "TP"),
        ("Zyxel Communications Corp.", "Z"),
        ("IKEA of Sweden", "I"),
        ("Fn-Link Technology", "F"),
        ("Quectel Wireless Solutions", "Q"),
        ("Kyocera Display", "K"),
        ("Raspberry Pi Trading", "RP"),
        ("Sichuan AI-Link Technology", "SA"),
        ("eero", "E"),
        ("Murata Manufacturing Co., Ltd.", "M"),
        ("3Com", "3"),
    ])
    func monogramLetters(_ brand: String, _ expected: String) {
        #expect(BrandMonogram.letters(for: brand) == expected)
    }

    @Test func monogramOfEmptyBrandIsNil() {
        #expect(BrandMonogram.letters(for: "") == nil)
        #expect(BrandMonogram.letters(for: " , ") == nil)
    }

    @Test func paletteIndexIsStableAndInRange() {
        // FNV-1a is fixed, so these values hold across launches (unlike `hashValue`).
        let a = BrandMonogram.paletteIndex(for: "Sonos", count: 10)
        #expect(a == BrandMonogram.paletteIndex(for: "Sonos", count: 10))
        #expect(a == BrandMonogram.paletteIndex(for: "SONOS Inc.", count: 10))
        for brand in ["Sonos", "Garmin", "Quectel", "TP-Link", "Murata", ""] {
            #expect((0..<10).contains(BrandMonogram.paletteIndex(for: brand, count: 10)))
        }
        #expect(BrandMonogram.paletteIndex(for: "Sonos", count: 0) == 0)
        // Different brands spread over the palette.
        let brands = [
            "Sonos", "Garmin", "Quectel", "TP-Link", "Murata", "Espressif", "Tuya", "Netgear", "Bose", "Roku",
        ]
        #expect(Set(brands.map { BrandMonogram.paletteIndex(for: $0, count: 10) }).count >= 5)
    }
}
