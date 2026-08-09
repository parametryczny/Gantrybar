import Foundation

enum SSDPResponseParser {
    static func parse(_ data: Data, fallbackHost: String? = nil) -> DiscoveredPrinter? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var headers: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let rawSerial = value(in: headers, keys: ["usn", "devserial.bambu.com", "serial-number"])
            .replacingOccurrences(of: "uuid:", with: "", options: .caseInsensitive)
        let serial = String(rawSerial.split(separator: "::", maxSplits: 1).first ?? "")
        guard !serial.isEmpty else { return nil }

        let location = value(in: headers, keys: ["location"])
        let host = hostFrom(location: location) ?? fallbackHost ?? ""
        guard !host.isEmpty else { return nil }

        let name = value(in: headers, keys: ["devname.bambu.com", "friendlyname", "name"])
        let model = value(in: headers, keys: ["devmodel.bambu.com", "modelname", "model"])
        return DiscoveredPrinter(
            serial: serial,
            name: name.isEmpty ? "Bambu \(serial.suffix(4))" : name,
            model: model.isEmpty ? "Bambu Lab" : model,
            host: host
        )
    }

    private static func value(in headers: [String: String], keys: [String]) -> String {
        for key in keys where headers[key]?.isEmpty == false { return headers[key]! }
        return ""
    }

    private static func hostFrom(location: String) -> String? {
        if let url = URL(string: location), let host = url.host { return host }
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
