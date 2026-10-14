import Foundation

/// Browser addresses as they are stored: web pages only, without fragments, sign-in parts or
/// query values that look like secrets, so a saved address never carries a login link's token.
public enum BrowserAddress {
    static let secretNames = ["token", "secret", "password", "passwd", "auth", "session", "signature", "credential",
                              "apikey", "api_key", "otp", "jwt", "saml", "ticket", "bearer", "cookie"]
    static let secretExact: Set<String> = ["key", "code", "sig", "state", "nonce", "sid", "pin", "pass", "hash", "k"]

    public static func sanitized(_ raw: String) -> String? {
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 16 * 1024, var parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty else { return nil }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        if let items = parts.queryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !secretExact.contains(name) && !secretNames.contains(where: name.contains)
            }
            parts.queryItems = kept.isEmpty ? nil : kept
        }
        guard let address = parts.string else { return nil }
        return String(address.prefix(2_048))
    }

    /// Host and path for display and AI provenance; the query stays out.
    public static func short(_ address: String) -> String {
        guard let parts = URLComponents(string: address), let host = parts.host else { return String(address.prefix(120)) }
        let path = parts.path == "/" ? "" : parts.path
        return String((host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + path).prefix(160).description
    }
}
