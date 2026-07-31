import Foundation

enum DisplayFormatters {
    static func relative(_ date: Date, relativeTo reference: Date = .now) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(.current))
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func duration(_ interval: TimeInterval) -> String {
        Duration.seconds(max(0, interval)).formatted(.units(
            allowed: [.days, .hours, .minutes],
            width: .abbreviated,
            maximumUnitCount: 2
        ))
    }

    static func territory(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let name = Locale.current.localizedString(forRegionCode: code)
        return name.map { "\($0) (\(code))" } ?? code
    }
}

