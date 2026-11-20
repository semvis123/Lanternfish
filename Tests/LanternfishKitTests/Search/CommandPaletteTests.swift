import Testing

@testable import LanternfishKit

@Suite struct FuzzyMatchTests {
    @Test func subsequenceMatchesAndMisses() {
        #expect(Fuzzy.match("nas", in: "Synology NAS") != nil)
        #expect(Fuzzy.match("snas", in: "Synology NAS") != nil)
        #expect(Fuzzy.match("xyz", in: "Synology NAS") == nil)
        #expect(Fuzzy.match("nass", in: "Synology NAS") == nil)
        #expect(Fuzzy.match("", in: "anything")?.positions == [])
    }

    @Test func scatteredMatchesAreRejected() {
        #expect(Fuzzy.match("nas", in: "Sichuan AI-Link Smart Device") == nil)
        #expect(Fuzzy.match("nas", in: "truenas") != nil)
        #expect(Fuzzy.match("nas", in: "Network Attached Storage")?.positions == [0, 8, 17])
        #expect(Fuzzy.match("a", in: "Zyxel Router") == nil)
        #expect(Fuzzy.match("r", in: "Zyxel Router")?.positions == [6])
        #expect(Fuzzy.match("rtr", in: "Zyxel Router") == nil)
        #expect(Fuzzy.match("zyro", in: "Zyxel Router")?.positions == [0, 1, 6, 7])
    }

    @Test func caseAndDiacriticInsensitive() {
        #expect(Fuzzy.match("MACBOOK", in: "Sam's MacBook Pro") != nil)
        #expect(Fuzzy.match("cafe", in: "Café Router") != nil)
    }

    @Test func positionsPreferWordStarts() {
        #expect(Fuzzy.match("nas", in: "Panasonic NAS")?.positions == [10, 11, 12])
        #expect(Fuzzy.match("mbp", in: "Sam's MacBook Pro")?.positions == [6, 9, 14])
        #expect(Fuzzy.match("sn", in: "Sam's NAS")?.positions == [0, 6])
    }

    @Test func rankingPrefersBoundariesAndContiguity() {
        func score(_ q: String, _ s: String) -> Int { Fuzzy.match(q, in: s)?.score ?? .min }
        #expect(score("nas", "Synology NAS") > score("nas", "Panasonic"))
        #expect(score("tv", "Samsung TV") > score("tv", "Stove Vent"))
        #expect(score("route", "Router") > score("route", "Raspberry Outlet Event"))
        #expect(score("192.168.1.1", "192.168.1.1") > score("192.168.1.1", "192.168.1.10"))
        #expect(score("1.10", "192.168.1.10") > score("1.10", "192.168.1.100") - 5)
    }

    @Test func multiTokenQueriesMatchAcrossFields() {
        let fields = [FuzzyText("Sam's iPad"), FuzzyText("192.168.1.66 · Apple iPad Air")]
        let m = Fuzzy.match(FuzzyQuery("ipad 66"), fields: fields)
        #expect(m != nil)
        #expect(m?.positions[0] == [6, 7, 8, 9])
        #expect(m?.positions[1]?.contains(10) == true)
        #expect(Fuzzy.match(FuzzyQuery("ipad zz"), fields: fields) == nil)
    }

    @Test func fieldWeightsFavorTheTitle() {
        let a = Fuzzy.match(FuzzyQuery("nas"), fields: [FuzzyText("NAS"), FuzzyText("x")], weights: [100, 50])!
        let b = Fuzzy.match(FuzzyQuery("nas"), fields: [FuzzyText("x"), FuzzyText("NAS")], weights: [100, 50])!
        #expect(a.score > b.score)
    }

    @Test func hostQueries() {
        #expect(HostQuery.parse("192.168.1.4") == .ip(IPv4Address("192.168.1.4")!))
        #expect(HostQuery.parse(" 10.0.0.1 ") == .ip(IPv4Address("10.0.0.1")!))
        #expect(HostQuery.parse("http://192.168.1.1:8080/admin") == .ip(IPv4Address("192.168.1.1")!))
        #expect(HostQuery.parse("nas.local") == .hostname("nas.local"))
        #expect(HostQuery.parse("Example.COM") == .hostname("example.com"))
        #expect(HostQuery.parse("https://apple.com/mac") == .hostname("apple.com"))
        #expect(HostQuery.parse("nas") == nil)
        #expect(HostQuery.parse("192.168") == nil)
        #expect(HostQuery.parse("192.168.1") == nil)
        #expect(HostQuery.parse("sam's ipad") == nil)
        #expect(HostQuery.parse("foo..bar") == nil)
        #expect(HostQuery.parse("") == nil)
    }
}
