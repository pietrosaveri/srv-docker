import Foundation

/// Draft of the planned Scandinavia and Baltics route.
/// Times marked "da confermare" in the notes are estimates to check before booking.
enum SampleItinerary {
    static let title = "Scandinavia e Baltici"

    static func legs() -> [Leg] {
        let rome = "Europe/Rome", sto = "Europe/Stockholm", hel = "Europe/Helsinki"
        let tll = "Europe/Tallinn", rix = "Europe/Riga", vno = "Europe/Vilnius"

        func p(_ name: String, _ lat: Double, _ lon: Double, _ tz: String) -> Place {
            Place(name: name, latitude: lat, longitude: lon, timeZoneID: tz)
        }
        func d(_ s: String, _ tz: String) -> Date {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm"
            f.timeZone = TimeZone(identifier: tz)
            return f.date(from: s) ?? .now
        }

        let mxp = p("Milano Malpensa", 45.6306, 8.7281, rome)
        let got = p("Goteborg Landvetter", 57.6628, 12.2798, sto)
        let gotCity = p("Goteborg Nils Ericson Terminal", 57.7089, 11.9733, sto)
        let stoCity = p("Stockholm Cityterminalen", 59.3313, 18.0560, sto)
        let stoFerry = p("Stockholm Stadsgarden (Viking Line)", 59.3165, 18.0880, sto)
        let tkuPort = p("Turku porto", 60.4350, 22.2190, hel)
        let tkuStation = p("Turku stazione", 60.4537, 22.2531, hel)
        let helCentral = p("Helsinki stazione centrale", 60.1719, 24.9414, hel)
        let helPort = p("Helsinki West Harbour", 60.1561, 24.9218, hel)
        let tllPort = p("Tallinn D-Terminal", 59.4440, 24.7672, tll)
        let tllStation = p("Tallinn Balti jaam", 59.4400, 24.7372, tll)
        let cesis = p("Cesis stazione", 57.3127, 25.2747, rix)
        let sigulda = p("Sigulda stazione", 57.1527, 24.8530, rix)
        let rigaStation = p("Riga stazione centrale", 56.9466, 24.1196, rix)
        let rigaBus = p("Riga autostazione", 56.9449, 24.1159, rix)
        let vnoBus = p("Vilnius autostazione", 54.6713, 25.2832, vno)
        let vnoAir = p("Vilnius aeroporto", 54.6341, 25.2858, vno)

        return [
            Leg(mode: .plane, from: mxp, to: got,
                departure: d("2026-11-28 10:25", rome), arrival: d("2026-11-28 12:45", sto),
                carrier: "Ryanair", notes: "Arrivo 12:45. Orario di partenza da confermare."),
            Leg(mode: .bus, from: gotCity, to: stoCity,
                departure: d("2026-11-29 08:20", sto), arrival: d("2026-11-29 15:00", sto),
                carrier: "FlixBus", price: "46,98 EUR",
                notes: "Alternativa: treno SJ diretto 08:19, arrivo 12:40, circa 80 EUR."),
            Leg(mode: .ferry, from: stoFerry, to: tkuPort,
                departure: d("2026-12-01 20:00", sto), arrival: d("2026-12-02 07:35", hel),
                carrier: "Viking Line", number: "Viking Glory", seat: "Cabina Inside Two",
                price: "56 EUR in due"),
            Leg(mode: .train, from: tkuStation, to: helCentral,
                departure: d("2026-12-02 08:30", hel), arrival: d("2026-12-02 10:30", hel),
                carrier: "VR", notes: "Orario da confermare su vr.fi. Bus dal porto alla stazione circa 15 min."),
            Leg(mode: .ferry, from: helPort, to: tllPort,
                departure: d("2026-12-06 07:30", hel), arrival: d("2026-12-06 09:30", tll),
                notes: "Operatore e orario da confermare (Tallink, Viking o Eckero)."),
            Leg(mode: .train, from: tllStation, to: cesis,
                departure: d("2026-12-07 10:22", tll), arrival: d("2026-12-07 15:27", rix),
                carrier: "Elron", price: "24,00 a 27,40 EUR",
                notes: "Treno diretto. Biglietti in vendita circa 2 settimane prima."),
            Leg(mode: .train, from: cesis, to: sigulda,
                departure: d("2026-12-08 09:30", rix), arrival: d("2026-12-08 10:05", rix),
                carrier: "Vivi", price: "2,80 a 3,90 EUR", notes: "Orario da confermare su vivi.lv."),
            Leg(mode: .train, from: sigulda, to: rigaStation,
                departure: d("2026-12-08 13:59", rix), arrival: d("2026-12-08 15:06", rix),
                carrier: "Vivi", price: "2,80 a 3,80 EUR"),
            Leg(mode: .bus, from: rigaBus, to: vnoBus,
                departure: d("2026-12-09 06:15", rix), arrival: d("2026-12-09 10:38", vno),
                carrier: "FlixBus", price: "8,48 EUR"),
            Leg(mode: .plane, from: vnoAir, to: mxp,
                departure: d("2026-12-09 17:50", vno), arrival: d("2026-12-09 18:40", rome),
                notes: "Partenza 17:50. Aeroporto di arrivo e orario da confermare."),
        ]
    }
}
