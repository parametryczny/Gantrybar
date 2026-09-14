import Foundation

extension AppSettings {
    /// A count with its noun in the right grammatical form. Polish has three forms (1 filament,
    /// 2 filamenty, 5 filamentów) and English two, while the catalogue maps one string to one string,
    /// so counts go through here instead of a translated key.
    func counted(_ count: Int, english: (one: String, other: String),
                 polish: (one: String, few: String, many: String)) -> String {
        guard isPolish else { return "\(count) \(count == 1 ? english.one : english.other)" }
        let units = count % 10, tens = count % 100
        let noun = count == 1 ? polish.one
            : (2...4).contains(units) && !(12...14).contains(tens) ? polish.few : polish.many
        return "\(count) \(noun)"
    }
}
