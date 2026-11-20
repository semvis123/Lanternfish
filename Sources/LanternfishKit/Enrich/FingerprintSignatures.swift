import Foundation

// The signature table. Weights: ~0.9 = conclusive on its own (a product name), ~0.6–0.8 = strong
// (a vendor-specific service or port), ~0.3–0.5 = suggestive (an OUI vendor that makes several
// kinds of things), ≤ 0.2 = weak hints that only help in combination.

extension Fingerprint {
    private static func re(_ p: String) -> NSRegularExpression {
        // Patterns are compile-time constants; a typo should fail loudly in tests.
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    static func brand(_ p: String, _ w: Double, _ why: String? = nil) -> Clue {
        Clue(test: .brand(re(p)), weight: w, why: why)
    }
    static func name(_ p: String, _ w: Double, _ why: String? = nil) -> Clue {
        Clue(test: .name(re(p)), weight: w, why: why)
    }
    static func text(_ p: String, _ w: Double, _ why: String? = nil) -> Clue {
        Clue(test: .text(re(p)), weight: w, why: why)
    }
    static func service(_ s: String..., w: Double, _ why: String? = nil) -> Clue {
        Clue(test: .service(Set(s.map { $0.lowercased() })), weight: w, why: why)
    }
    static func port(_ p: UInt16..., w: Double, _ why: String? = nil) -> Clue {
        Clue(test: .anyPort(Set(p)), weight: w, why: why)
    }
    static func ports(_ p: UInt16..., w: Double, _ why: String? = nil) -> Clue {
        Clue(test: .allPorts(Set(p)), weight: w, why: why)
    }
    static func gateway(_ w: Double) -> Clue { Clue(test: .gateway, weight: w) }
    static func privateMAC(_ w: Double, _ why: String? = nil) -> Clue { Clue(test: .privateMAC, weight: w, why: why) }

    static func sig(
        _ label: String, _ manufacturer: String?, _ model: String?, _ kind: DeviceKind?,
        model pattern: String? = nil, spaces: Bool = false, _ clues: [Clue]
    ) -> Signature {
        Signature(
            label: label, manufacturer: manufacturer, model: model, kind: kind, clues: clues,
            modelPattern: pattern.map(re), spaceSeparators: spaces)
    }

    /// Ordered most specific first: on equal confidence the earlier signature wins.
    static let signatures: [Signature] =
        apple + phones + tvs + speakers + smartHome + cameras + printers
        + nas + network + consoles + computers + wearables + modules

    // MARK: Apple

    static let apple: [Signature] = [
        sig(
            "iPhone", "Apple", "iPhone", .phone,
            [
                text(#"iphone"#, 0.9), port(62078, w: 0.4, "iOS sync service"), service("apple device", w: 0.15),
            ]),
        sig(
            "iPad", "Apple", "iPad", .tablet,
            [
                text(#"ipad"#, 0.9), port(62078, w: 0.4, "iOS sync service"), service("apple device", w: 0.15),
            ]),
        sig(
            "Apple Watch", "Apple", "Apple Watch", .phone,
            [
                name(#"^(apple[-_ ]?)?watch\b|[-_ ]watch$|watch[-_ ]van[-_ ]|^watchos"#, 0.75),
                text(#"apple ?watch"#, 0.9),
                privateMAC(0.1),
            ]),
        sig(
            "Apple TV", "Apple", "Apple TV", .tv,
            [
                text(#"apple[-_ ]?tv|appletv"#, 0.9), service("remote", w: 0.3),
            ]),
        sig("HomePod", "Apple", "HomePod", .speaker, [text(#"homepod|audioaccessory"#, 0.9)]),
        sig(
            "Mac", "Apple", nil, .computer,
            model: #"(macbook[ -]?(?:pro|air)?|imac(?: pro)?|mac ?mini|mac ?studio|mac ?pro)"#,
            [
                text(#"macbook|imac|mac[-_ ]?mini|mac[-_ ]?studio|mac[-_ ]?pro|^mac\d"#, 0.85),
                service("file sharing (smb)", "file sharing (afp)", "screen sharing", w: 0.2),
                service("apple device", w: 0.15),
            ]),
        sig(
            "iPhone or iPad", "Apple", "iPhone or iPad", .phone,
            [
                port(62078, w: 0.55, "only iPhones and iPads run this"), brand(#"^apple"#, 0.2), privateMAC(0.05),
            ]),
        sig(
            "Apple device", "Apple", nil, nil,
            [
                service("apple device", "airplay", w: 0.4), brand(#"^apple"#, 0.35),
            ]),
    ]

    // MARK: Phones / tablets (non-Apple)

    static let phones: [Signature] = [
        sig(
            "Samsung Galaxy Tab", "Samsung", "Galaxy Tab", .tablet, model: #"(galaxy[-_ ]?tab[-_ ]?[a-z0-9]*)"#,
            spaces: true,
            [
                text(#"galaxy[-_ ]?tab|^sm-[tx]\d"#, 0.9), brand(#"samsung"#, 0.2),
            ]),
        sig(
            "Samsung Galaxy phone", "Samsung", "Galaxy", .phone, model: #"(galaxy[-_ ][a-z0-9][a-z0-9 _-]*)"#,
            spaces: true,
            [
                text(#"galaxy|^sm-[asgfmnez]\d"#, 0.85), brand(#"samsung"#, 0.2), privateMAC(0.05),
            ]),
        sig(
            "Google Pixel", "Google", "Pixel", .phone, model: #"(pixel[-_ ][0-9a-z ]+)"#, spaces: true,
            [
                text(#"^pixel[-_ ]|google[-_ ]pixel"#, 0.85)
            ]),
        sig(
            "Android phone", nil, nil, .phone,
            model:
                #"(oneplus[-_ ]?\w*|redmi[-_ ]?\w*|xiaomi[-_ ]?\w*|huawei[-_ ]?\w*|honor[-_ ]?\w*|oppo[-_ ]?\w*|vivo[-_ ]?\w*|realme[-_ ]?\w*|moto[-_ ]?g\w*|nokia[-_ ]?\w*|fairphone\w*)"#,
            spaces: true,
            [
                text(
                    #"oneplus|redmi|^poco|huawei-|^honor|^oppo|^vivo|realme|moto[-_ ]?[geg]\d|^nokia|fairphone|^xiaomi"#,
                    0.75),
                text(#"^android[-_][0-9a-f]{6,}"#, 0.7, "Android's default hostname"),
                text(#"^android$|android"#, 0.35),
            ]),
        sig(
            "Kindle / Fire tablet", "Amazon", "Fire tablet", .tablet, [text(#"kindle|fire[-_ ]?hd|^kf[a-z]{2,}"#, 0.85)]
        ),
    ]

    // MARK: TVs and streaming

    static let tvs: [Signature] = [
        sig(
            "Sony BRAVIA TV", "Sony", "BRAVIA TV", .tv, model: #"\b((?:KD|XR|KDL|KE|FWD)-?\d{2}[A-Z0-9]+)"#,
            [
                text(#"bravia"#, 0.85), text(#"\b(KD|XR|KDL|KE|FWD)-?\d{2}[A-Z]\w*"#, 0.85, "Sony TV model number"),
                brand(#"sony"#, 0.3), service("android tv", w: 0.45), service("chromecast", w: 0.3),
            ]),
        sig(
            "Samsung TV", "Samsung", "Smart TV", .tv, model: #"\b([QU]E?\d{2}[A-Z]{1,3}\d{2,4}[A-Z]*)"#,
            [
                text(#"samsung.*\btv\b|\btizen\b|\[tv\] samsung|\b[QU]E?\d{2}(Q|LS|TU|AU|BU|CU|DU|QN)\w*"#, 0.8),
                port(8001, 8002, w: 0.7, "Samsung TV remote API"), brand(#"samsung"#, 0.2),
            ]),
        sig(
            "LG TV", "LG", "webOS TV", .tv, model: #"\b(OLED\d{2}[A-Z0-9]+|\d{2}(?:NANO|UN|UP|UQ|UR|QNED)\w+)"#,
            [
                text(#"webos|lgwebostv|\[lg\]|\bOLED\d{2}[A-Z]|\b\d{2}(NANO|UN|UP|UQ|UR|QNED)\d"#, 0.85),
                brand(#"^lg\b|lg electronics|lg innotek"#, 0.3), ports(3000, 3001, w: 0.35, "webOS remote API"),
            ]),
        sig(
            "Philips TV", "Philips", "Smart TV", .tv,
            [
                text(#"philips.*tv|\b\d{2}(PUS|OLED|PML)\d{3,4}"#, 0.8), brand(#"tp vision"#, 0.6),
            ]),
        sig("Hisense / TCL TV", nil, "Smart TV", .tv, [text(#"hisense|vidaa|\btcl\b"#, 0.7)]),
        sig("Roku", "Roku", nil, .tv, [text(#"roku"#, 0.9), brand(#"roku"#, 0.7), port(8060, w: 0.7, "Roku ECP")]),
        sig(
            "Amazon Fire TV", "Amazon", "Fire TV", .tv,
            [
                service("amazon fire tv", w: 0.8), text(#"fire[-_ ]?tv|firestick|^aft[a-z]"#, 0.85),
                brand(#"amazon"#, 0.2),
            ]),
        sig("NVIDIA Shield", "NVIDIA", "Shield TV", .tv, [text(#"shield"#, 0.75), brand(#"nvidia"#, 0.4)]),
        sig(
            "Chromecast", "Google", "Chromecast", .tv,
            [
                text(#"chromecast"#, 0.85), service("chromecast", w: 0.5), ports(8008, 8009, w: 0.3, "Cast"),
                brand(#"google"#, 0.2),
            ]),
        sig(
            "Android TV", nil, "Android TV", .tv,
            [service("android tv", w: 0.75), text(#"android ?tv|google ?tv"#, 0.8)]),
    ]

    // MARK: Speakers

    static let speakers: [Signature] = [
        sig(
            "Sonos", "Sonos", nil, .speaker,
            [
                brand(#"sonos"#, 0.7), service("sonos", w: 0.8), port(1400, 1443, w: 0.55, "Sonos control"),
                text(#"sonos"#, 0.75),
            ]),
        sig(
            "Google Nest speaker", "Google", "Nest speaker", .speaker,
            [
                text(#"google[-_ ]?home|nest[-_ ]?(mini|audio|hub)|google[-_ ]?nest"#, 0.85),
                service("chromecast", w: 0.3),
            ]),
        sig(
            "Amazon Echo", "Amazon", "Echo", .speaker,
            [
                text(#"\becho\b|alexa|^amazon-[0-9a-f]{6,}"#, 0.75), brand(#"amazon"#, 0.3),
            ]),
        sig("Bose", "Bose", nil, .speaker, [text(#"bose|soundtouch"#, 0.8), brand(#"bose"#, 0.6)]),
        sig(
            "Denon / Marantz HEOS", nil, nil, .speaker,
            [text(#"\bheos|denon|marantz"#, 0.75), brand(#"d&m holdings|sound united"#, 0.6)]),
        sig("Yamaha MusicCast", "Yamaha", nil, .speaker, [text(#"musiccast|yamaha"#, 0.7), brand(#"yamaha"#, 0.5)]),
        sig("AirPlay speaker", nil, "AirPlay speaker", .speaker, [service("airplay audio", w: 0.4)]),
    ]

    // MARK: Smart home

    static let smartHome: [Signature] = [
        sig(
            "Philips Hue Bridge", "Philips Hue", "Hue Bridge", .iot,
            [
                text(#"philips[-_ ]?hue|hue[-_ ]?bridge|^hue$"#, 0.85), service("philips hue", w: 0.9),
                brand(#"signify|philips lighting|philips hue"#, 0.7),
            ]),
        sig(
            "IKEA DIRIGERA", "IKEA", "DIRIGERA Hub", .iot,
            [text(#"dirigera"#, 0.9), brand(#"ikea"#, 0.4), name(#"^gw\d-[0-9a-f]{8,}"#, 0.4)]),
        sig(
            "IKEA TRÅDFRI gateway", "IKEA", "TRÅDFRI Gateway", .iot,
            [text(#"tradfri|trådfri"#, 0.9), brand(#"ikea"#, 0.4)]),
        sig(
            "Shelly", "Shelly", nil, .iot,
            model: #"(shelly[-_ ]?(?:plus|pro|mini)?[-_ ]?[0-9a-z]+?)(?:-[0-9a-f]{6,12})?$"#,
            [
                text(#"shelly"#, 0.85), service("shelly", w: 0.9), brand(#"allterco|shelly"#, 0.6),
            ]),
        sig(
            "ESPHome", nil, nil, .iot,
            [service("esphome", w: 0.9), port(6053, w: 0.75, "ESPHome API"), text(#"esphome"#, 0.85)]),
        sig("Tasmota", nil, nil, .iot, [text(#"tasmota"#, 0.9)]),
        sig("WLED", nil, "WLED light", .iot, [text(#"\bwled"#, 0.9), service("wled", w: 0.9)]),
        sig(
            "Tuya / Smart Life", "Tuya", "Smart device", .iot,
            [
                port(6668, w: 0.7, "Tuya local protocol"), brand(#"tuya"#, 0.6), text(#"smart ?life|^tuya"#, 0.7),
            ]),
        sig(
            "Home Assistant", nil, "Home Assistant", .iot,
            [
                text(#"home[-_ ]?assistant"#, 0.85), service("home assistant", w: 0.85),
                port(8123, w: 0.6, "Home Assistant"),
            ]),
        sig(
            "Toon thermostat", "Quby", "Toon thermostat", .iot,
            [
                name(#"^qb-\d{6,}"#, 0.75, "Quby/Toon serial"), text(#"z-wave"#, 0.35), text(#"\btoon\b|eneco"#, 0.85),
            ]),
        sig(
            "Nest thermostat/Protect", "Google", "Nest", .iot,
            [
                text(#"nest[-_ ]?(thermostat|protect|learning)"#, 0.85), brand(#"nest labs"#, 0.7),
            ]),
        sig(
            "Thermostat", nil, "Thermostat", .iot,
            [
                text(#"\btado\b|netatmo|ecobee|honeywell|evohome|thermostat"#, 0.8),
                brand(#"tado|netatmo|ecobee|resideo"#, 0.7),
            ]),
        sig(
            "Robot vacuum", nil, "Robot vacuum", .iot,
            [
                text(#"roborock|rockrobo|viomi|dreame|roidmi|roomba|irobot|deebot|ecovacs"#, 0.85),
                brand(#"irobot|roborock|ecovacs|dreame"#, 0.7),
            ]),
        sig(
            "TP-Link Kasa", "TP-Link", "Kasa smart device", .iot,
            [
                text(#"\bkasa\b|^(hs|kp|ks|ep)\d{3}"#, 0.8), port(9999, w: 0.6, "Kasa local protocol"),
                brand(#"tp-?link"#, 0.2),
            ]),
        sig(
            "TP-Link Tapo", "TP-Link", "Tapo smart device", .iot,
            [text(#"^tapo|^(p1\d{2}|l5\d{2}|l9\d{2})$"#, 0.8), brand(#"tp-?link"#, 0.2)]),
        sig(
            "Smart plug / light", nil, nil, .iot,
            [
                text(#"meross|govee|lifx|nanoleaf|sonoff|ewelink|wiz[-_ ]|yeelight|athom|nous"#, 0.8),
                service("ewelink", w: 0.85), brand(#"itead|lifi labs|nanoleaf|signify"#, 0.5),
            ]),
        sig(
            "Smart home hub", nil, "Smart home hub", .iot,
            [text(#"smartthings|homey|hubitat|zigbee|z-wave|deconz|conbee"#, 0.7)]),
        sig(
            "HomeKit accessory", nil, nil, .iot,
            [service("homekit", w: 0.45), service("matter", w: 0.4), service("thread", w: 0.3)]),
        sig("Tesla", "Tesla", nil, .iot, [text(#"tesla"#, 0.75), brand(#"tesla"#, 0.8)]),
        sig("EV charger", nil, "EV charger", .iot, [text(#"easee|zaptec|wallbox|alfen|ocpp"#, 0.8)]),
        sig(
            "Espressif-based", "Espressif", nil, .iot, model: #"\b(esp32(?:-[a-z]\d)?|esp8266)\b"#,
            [
                brand(#"espressif"#, 0.55, "Wi-Fi chip used in smart-home gadgets"),
                text(#"^esp(32|8266)?[-_][0-9a-f]{4,}|^esp32|^esp8266"#, 0.6),
            ]),
    ]

    // MARK: Cameras

    static let cameras: [Signature] = [
        sig("Hikvision camera", "Hikvision", nil, .camera, [text(#"hikvision"#, 0.85), brand(#"hikvision"#, 0.75)]),
        sig(
            "Dahua camera", "Dahua", nil, .camera,
            [text(#"dahua"#, 0.85), brand(#"dahua"#, 0.75), port(37777, w: 0.7, "Dahua DVR")]),
        sig("Reolink camera", "Reolink", nil, .camera, [text(#"reolink"#, 0.85), brand(#"reolink"#, 0.75)]),
        sig(
            "Ring", "Ring", nil, .camera,
            [text(#"^ring[-_]|ring ?(doorbell|cam|stick|chime)"#, 0.8), brand(#"^ring\b"#, 0.6)]),
        sig("Arlo", "Arlo", nil, .camera, [text(#"arlo"#, 0.85), brand(#"arlo"#, 0.75)]),
        sig("Wyze / Eufy camera", nil, nil, .camera, [text(#"wyze|eufy"#, 0.8), brand(#"wyze|anker"#, 0.4)]),
        sig("TP-Link Tapo camera", "TP-Link", "Tapo camera", .camera, [text(#"tapo[-_ ]?c\d{3}|^c\d{3}$"#, 0.85)]),
        sig(
            "UniFi Protect camera", "Ubiquiti", "UniFi Protect camera", .camera,
            [text(#"\buvc\b|\bg[3-6][-_ ](bullet|dome|flex|instant|pro)"#, 0.8)]),
        sig(
            "IP camera", nil, nil, .camera,
            [
                text(#"ip ?cam|ipcam|webcam|doorbell|camera"#, 0.75), ports(554, 8899, w: 0.6, "RTSP + ONVIF"),
                port(8554, w: 0.3),
            ]),
    ]

    // MARK: Printers

    static let printers: [Signature] = [
        sig(
            "Bambu Lab 3D printer", "Bambu Lab", "3D Printer", .printer,
            [
                brand(#"bambu"#, 0.9), service("bambu lab", w: 0.9),
                ports(8883, 990, w: 0.5, "MQTT + FTPS like Bambu printers"),
            ]),
        sig(
            "Prusa / OctoPrint", nil, "3D Printer", .printer,
            [text(#"prusa|octoprint|klipper|mainsail|fluidd|creality"#, 0.8)]),
        sig(
            "HP printer", "HP", nil, .printer,
            model: #"((?:color )?(?:laserjet|officejet|deskjet|envy|pagewide|smart tank|photosmart)[a-z0-9 +-]*)"#,
            [
                text(
                    #"officejet|laserjet|deskjet|\benvy\b|pagewide|smart tank|photosmart|^hp[0-9a-f]{6}$|^npi[0-9a-f]{6}"#,
                    0.85),
                brand(#"hewlett|^hp\b"#, 0.35), port(631, 9100, w: 0.45),
            ]),
        sig(
            "Epson printer", "Epson", nil, .printer, model: #"\b((?:ET|WF|XP|L|EW|EC)-?\d{3,5}\w*)"#,
            [
                text(#"epson|\b(ET|WF|XP|EW)-\d{3,4}"#, 0.85), brand(#"epson"#, 0.5), port(631, 9100, w: 0.45),
            ]),
        sig(
            "Brother printer", "Brother", nil, .printer, model: #"\b((?:MFC|HL|DCP|ADS)-[A-Z0-9]+)"#,
            [
                text(#"brother|^br[nw][0-9a-f]{6,}|\b(MFC|HL|DCP)-[A-Z0-9]{3,}"#, 0.85), brand(#"brother"#, 0.5),
                port(631, 9100, w: 0.45),
            ]),
        sig(
            "Canon printer", "Canon", nil, .printer,
            model: #"\b((?:PIXMA|MAXIFY|imageCLASS|i-SENSYS)\s?[A-Z]*\d+\w*|(?:MF|LBP|TS|TR|G)\d{3,4}\w*)"#,
            [
                text(#"canon|pixma|maxify|imageclass|i-sensys"#, 0.85), brand(#"canon"#, 0.5), port(631, 9100, w: 0.45),
            ]),
        sig(
            "Kyocera printer", "Kyocera", nil, .printer, model: #"\b((?:ECOSYS|TASKalfa)\s+[A-Z0-9][A-Za-z0-9]+)"#,
            [
                text(#"kyocera|ecosys|taskalfa"#, 0.85), brand(#"kyocera"#, 0.6), port(631, 9100, w: 0.45),
            ]),
        sig(
            "Office printer", nil, nil, .printer,
            [
                text(#"lexmark|ricoh|xerox|konica|bizhub|sharp mx|oki(data)?|zebra"#, 0.8),
                brand(#"lexmark|ricoh|xerox|konica|sharp|oki data|zebra"#, 0.5), port(631, 9100, w: 0.45),
            ]),
        sig(
            "Printer", nil, nil, .printer,
            [
                service("printer", w: 0.75), port(631, w: 0.5, "IPP"), port(9100, w: 0.55, "raw printing"),
                port(515, w: 0.3, "LPD"),
                service("scanner", w: 0.4),
            ]),
    ]

    // MARK: NAS / servers

    static let nas: [Signature] = [
        sig(
            "Synology NAS", "Synology", "DiskStation", .nas, model: #"\b((?:DS|RS|DVA|FS)\d{3,4}(?:\+|j|xs\+?|play)?)"#,
            [
                text(#"synology|diskstation|\b(DS|RS)\d{3,4}(\+|j|xs|play)?\b"#, 0.85), brand(#"synology"#, 0.8),
                ports(5000, 5001, w: 0.35, "DSM web ports"),
            ]),
        sig(
            "QNAP NAS", "QNAP", nil, .nas, model: #"\b(T[SVBRH]-[A-Z0-9]{3,8})\b"#,
            [
                text(#"qnap|\bT[SVBRH]-\d{3}"#, 0.85), brand(#"qnap"#, 0.8),
            ]),
        sig("TrueNAS", nil, nil, .nas, [text(#"truenas|freenas"#, 0.9)]),
        sig(
            "NAS", nil, nil, .nas,
            [
                text(#"unraid|openmediavault|readynas|my ?cloud|\bnas\b|terramaster|asustor"#, 0.8),
                brand(#"western digital|terramaster|asustor|buffalo"#, 0.4),
                service("time machine", w: 0.35),
            ]),
        sig(
            "Raspberry Pi", "Raspberry Pi", nil, .computer,
            [brand(#"raspberry"#, 0.85), text(#"raspberry ?pi|raspberrypi|raspbian|^rpi\d?\b"#, 0.8)]),
        sig(
            "Proxmox host", nil, nil, .computer,
            [text(#"proxmox|^pve\d*$"#, 0.85), port(8006, w: 0.6, "Proxmox web UI")]),
        sig("Media server", nil, nil, .computer, [text(#"\bplex\b|jellyfin|emby"#, 0.6), port(32400, 8096, w: 0.5)]),
        sig("Pi-hole", nil, nil, .computer, [text(#"pi-hole|pihole"#, 0.75), port(4711, w: 0.5)]),
    ]

    // MARK: Network equipment

    static let network: [Signature] = [
        sig(
            "Netgear router", "Netgear", nil, .router,
            model: #"\b((?:RAX|RAXE|RBR|RBS|RBK|RBE|CAX|LAX|XR|MR|MK|EX|WAX|WAC|R)\d{2,4}[A-Z]{0,3})\b"#,
            [
                brand(#"netgear"#, 0.55),
                text(
                    #"^(RAX|RAXE|RBR|RBS|RBK|RBE|CAX|LAX|XR|MR|MK|EX|WAX|WAC)\d{2,4}[A-Z]{0,3}\b|orbi|readyshare|routerlogin"#,
                    0.75),
                gateway(0.4),
            ]),
        sig("FRITZ!Box", "AVM", "FRITZ!Box", .router, [text(#"fritz"#, 0.9), brand(#"^avm"#, 0.7)]),
        sig(
            "TP-Link Deco", "TP-Link", "Deco", .router, model: #"(deco[-_ ]?[a-z]{0,2}\d+\w*)"#, spaces: true,
            [
                text(#"\bdeco[-_ ]?([a-z]{1,2}\d|\d)"#, 0.85), brand(#"tp-?link"#, 0.25),
            ]),
        sig(
            "TP-Link router", "TP-Link", nil, .router,
            model: #"(archer[-_ ]?[a-z]{1,3}\d+\w*|tl-[a-z]+\d+\w*|re\d{3}x?)"#, spaces: true,
            [
                text(#"archer[-_ ]?[a-z]{1,3}\d|\btl-(wr|mr|wa|er)\d|^re\d{3}x?\b"#, 0.85), brand(#"tp-?link"#, 0.25),
                gateway(0.4),
            ]),
        sig(
            "Ubiquiti UniFi", "Ubiquiti", nil, .router,
            [
                brand(#"ubiquiti"#, 0.7), text(#"unifi|ubnt|\b(UAP|USW|UDM|UCG|UXG|U6|U7)\b|airos"#, 0.75),
                port(10001, w: 0.45, "Ubiquiti discovery"),
            ]),
        sig(
            "Mesh Wi-Fi", nil, nil, .router,
            [text(#"\beero\b|velop|google ?wifi|nest ?wifi|zenwifi|amplifi|plume|\bmesh\b"#, 0.8)]),
        sig(
            "MikroTik", "MikroTik", nil, .router,
            [text(#"mikrotik|routeros"#, 0.85), brand(#"mikrotik|routerboard"#, 0.8), port(8291, w: 0.7, "Winbox")]),
        sig(
            "Zyxel", "Zyxel", nil, .router,
            model: #"\b((?:VMG|EMG|XMG|NR|LTE|AX|DX|EX|WX|NBG|USG|ATP)\d{3,5}[A-Z]?(?:-[A-Z0-9]{2,6})?)\b"#,
            [
                brand(#"zyxel"#, 0.6), text(#"zyxel|\b(VMG|EMG|NR|DX|EX)\d{4}"#, 0.7), gateway(0.4),
            ]),
        sig(
            "ASUS router", "ASUS", nil, .router, model: #"\b((?:RT|GT|TUF|DSL)-[A-Z0-9_]{3,12})\b"#,
            [
                text(#"asuswrt|\b(RT|GT)-[A-Z]{1,3}\d{2,}"#, 0.85), brand(#"asustek"#, 0.2), gateway(0.4),
            ]),
        sig(
            "Router (gateway)", nil, nil, .router,
            [
                gateway(0.9), text(#"router|gateway|openwrt|pfsense|opnsense|dd-wrt|access ?point"#, 0.6),
            ]),
    ]

    // MARK: Game consoles

    static let consoles: [Signature] = [
        sig(
            "PlayStation", "Sony", "PlayStation", .gameConsole, model: #"(ps[345]|playstation ?\d?)"#,
            [
                text(#"playstation|\bps[345]\b|^ps[345][-_]"#, 0.85), brand(#"sony interactive"#, 0.85),
            ]),
        sig("Xbox", "Microsoft", "Xbox", .gameConsole, [text(#"xbox"#, 0.9), ports(3074, w: 0.3, "Xbox Live")]),
        sig(
            "Nintendo Switch", "Nintendo", "Switch", .gameConsole,
            [brand(#"nintendo"#, 0.85), text(#"nintendo|\bswitch\b"#, 0.6)]),
        sig(
            "Steam Deck", "Valve", "Steam Deck", .gameConsole,
            [text(#"steam ?deck|steamdeck"#, 0.9), brand(#"valve"#, 0.7)]),
    ]

    // MARK: Computers

    static let computers: [Signature] = [
        sig(
            "Windows PC", nil, "Windows PC", .computer,
            [
                name(#"^(desktop|laptop)-[a-z0-9]{5,}$"#, 0.85, "Windows default name"),
                text(#"^windows|\bwin(10|11)\b"#, 0.6),
                port(3389, w: 0.6, "Remote Desktop"), ports(135, 445, w: 0.5, "Windows RPC + SMB"),
            ]),
        sig(
            "Linux computer", nil, nil, .computer,
            [
                text(#"ubuntu|debian|fedora|centos|red hat|arch linux|linux mint|raspberry pi os|freebsd"#, 0.6),
                ports(22, 445, w: 0.35, "SSH + SMB"),
            ]),
        sig("Chromebook", "Google", "Chromebook", .computer, [text(#"chromebook|chromeos"#, 0.85)]),
        sig(
            "PC (vendor)", nil, nil, .computer,
            [
                brand(#"\bdell\b|lenovo|micro-star|gigabyte|asrock|intel corporate|framework"#, 0.4),
                port(22, 3389, 5900, w: 0.2),
            ]),
    ]

    // MARK: Wearables

    static let wearables: [Signature] = [
        sig(
            "Garmin wearable", "Garmin", "Watch or fitness device", .phone,
            [
                brand(#"garmin"#, 0.55), name(#"garmin|forerunner|fenix|venu|vivoactive|edge-?\d"#, 0.6),
            ]),
        sig("Fitbit", "Fitbit", nil, .phone, [brand(#"fitbit"#, 0.7), text(#"fitbit"#, 0.8)]),
    ]

    // MARK: Module vendors (weak; only decide when nothing better matched)

    static let modules: [Signature] = [
        sig(
            "Cellular module", "Quectel", "4G/5G module", nil,
            [
                brand(
                    #"quectel|sierra wireless|telit|fibocom|simcom"#, 0.4, "cellular modem module — routers, cars, IoT")
            ]),
        sig(
            "Cellular gateway", nil, "4G/5G gateway", .router,
            [
                brand(#"quectel|sierra wireless|telit|fibocom|simcom"#, 0.4, "cellular modem module"),
                port(53, w: 0.45, "runs DNS like a router"),
            ]),
        sig(
            "IoT Wi-Fi module", nil, nil, .iot,
            [
                brand(
                    #"fn-link|ai-link|murata|ampak|bouffalo|beken|gaoshengda|bilian|cypress|silicon lab|hi-flying|lumi united|universal electronics|wisol|chongqing fugui"#,
                    0.45, "Wi-Fi module found in smart-home gear and appliances"),
                port(80, 8000, 8080, w: 0.1),
            ]),
    ]
}
