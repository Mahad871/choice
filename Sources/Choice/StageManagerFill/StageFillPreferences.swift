import Foundation

enum StageReservationMode: String {
    /// Measure Stage Manager's strip on each display.
    case automatic
    /// Use the width the user entered.
    case custom
}

final class StageFillPreferences {
    static let defaultReservation = 220
    static let maximumReservation = 2000
    static let defaultShortcut = ShortcutConfiguration(enabled: false, control: true, option: true,
                                                      shift: false, command: true, key: "F")
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var enabled: Bool {
        get { defaults.object(forKey: "stageFillEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stageFillEnabled") }
    }

    var rememberPerDisplay: Bool {
        get { defaults.bool(forKey: "stageFillPerDisplay") }
        set { defaults.set(newValue, forKey: "stageFillPerDisplay") }
    }

    /// On by default since 2.0. An explicit earlier choice is kept.
    var titleBarDoubleClick: Bool {
        get { defaults.object(forKey: "stageFillTitleBarDoubleClick") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stageFillTitleBarDoubleClick") }
    }

    var greenButtonCompanion: Bool {
        get { defaults.object(forKey: "stageFillGreenButtonCompanion") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "stageFillGreenButtonCompanion") }
    }

    var reservationMode: StageReservationMode {
        get { StageReservationMode(rawValue: defaults.string(forKey: "stageFillReservationMode") ?? "") ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: "stageFillReservationMode") }
    }

    var shortcut: ShortcutConfiguration {
        get {
            guard let data = defaults.data(forKey: "stageFillShortcut"),
                  let value = try? PropertyListDecoder().decode(ShortcutConfiguration.self, from: data)
            else { return Self.defaultShortcut }
            return value
        }
        set {
            if let data = try? PropertyListEncoder().encode(newValue) {
                defaults.set(data, forKey: "stageFillShortcut")
            }
        }
    }

    var defaultReservation: Int {
        get {
            guard let saved = defaults.object(forKey: "stageFillDefaultReservation") as? Int else {
                return Self.defaultReservation
            }
            return Self.clamp(saved)
        }
        set { defaults.set(Self.clamp(newValue), forKey: "stageFillDefaultReservation") }
    }

    /// The custom width for a display. Automatic mode ignores it.
    func reservation(for displayKey: String) -> Int {
        guard rememberPerDisplay,
              let saved = (defaults.dictionary(forKey: "stageFillDisplayReservations") ?? [:])[displayKey] as? Int
        else { return defaultReservation }
        return Self.clamp(saved)
    }

    func setReservation(_ width: Int, for displayKey: String?) {
        guard let displayKey, rememberPerDisplay else {
            defaultReservation = width
            return
        }
        var widths = defaults.dictionary(forKey: "stageFillDisplayReservations") ?? [:]
        widths[displayKey] = Self.clamp(width)
        defaults.set(widths, forKey: "stageFillDisplayReservations")
    }

    /// The last stable strip measurement per display, so a fill works while the strip
    /// is hidden behind a large window.
    func measuredStrip(for displayKey: String) -> StageStripMeasurement? {
        guard let entry = (defaults.dictionary(forKey: "stageFillMeasuredStrips") ?? [:])[displayKey] as? [String: Any],
              let side = (entry["side"] as? String).flatMap(StageStripSide.init(rawValue:)),
              let extent = entry["extent"] as? Double else { return nil }
        return StageStripMeasurement(side: side, extent: CGFloat(extent))
    }

    func setMeasuredStrip(_ measurement: StageStripMeasurement, for displayKey: String) {
        var strips = defaults.dictionary(forKey: "stageFillMeasuredStrips") ?? [:]
        strips[displayKey] = ["side": measurement.side.rawValue, "extent": Double(measurement.extent)]
        defaults.set(strips, forKey: "stageFillMeasuredStrips")
    }

    func clearMeasuredStrip(for displayKey: String) {
        var strips = defaults.dictionary(forKey: "stageFillMeasuredStrips") ?? [:]
        strips[displayKey] = nil
        defaults.set(strips, forKey: "stageFillMeasuredStrips")
    }

    private static func clamp(_ width: Int) -> Int {
        min(max(0, width), maximumReservation)
    }
}
