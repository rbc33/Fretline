import Foundation

enum YouTubeVideoID {
    /// Extrae el ID de youtu.be/ID, watch?v=ID, /shorts/ID, /embed/ID, /live/ID o un ID suelto.
    static func parse(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let isID: (String) -> Bool = { $0.count == 11 && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }
        if isID(s) { return s }
        guard let url = URL(string: s), let host = url.host?.lowercased() else { return nil }

        if host.hasSuffix("youtu.be") {
            let id = String(url.path.dropFirst().prefix(11))
            return isID(id) ? id : nil
        }
        guard host.contains("youtube") else { return nil }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
           isID(v) {
            return v
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(where: { ["shorts", "embed", "live", "v"].contains($0) }), i + 1 < parts.count {
            let id = String(parts[i + 1].prefix(11))
            return isID(id) ? id : nil
        }
        return nil
    }
}
