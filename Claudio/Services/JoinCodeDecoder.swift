import Foundation

enum JoinCodeDecoder {
    private static let version: UInt8 = 0x01
    private static let charset = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let dashEvery = 4

    struct JoinCode {
        let serverURL: String   // includes https://
        let inviteCode: String
    }

    static func decode(_ code: String) -> JoinCode? {
        // Strip dashes, spaces, normalize to uppercase
        let clean = code.uppercased().filter { $0 != "-" && $0 != " " }
        guard !clean.isEmpty else { return nil }

        guard let payload = base32Decode(clean) else { return nil }
        guard payload.count >= 3 else { return nil }
        guard payload[0] == version else { return nil }

        // Find null separator
        guard let sepIdx = payload[1...].firstIndex(of: 0x00) else { return nil }

        let urlBytes = payload[1..<sepIdx]
        let inviteBytes = payload[(sepIdx + 1)...]

        guard !urlBytes.isEmpty, !inviteBytes.isEmpty else { return nil }

        guard let url = String(bytes: urlBytes, encoding: .utf8),
              let invite = String(bytes: inviteBytes, encoding: .utf8) else { return nil }

        return JoinCode(serverURL: "https://" + url, inviteCode: invite)
    }

    static func encode(serverURL: String, inviteCode: String) -> String {
        var url = serverURL
        for prefix in ["https://", "http://"] {
            if url.hasPrefix(prefix) {
                url = String(url.dropFirst(prefix.count))
            }
        }

        var payload = Data()
        payload.append(version)
        payload.append(contentsOf: Array(url.utf8))
        payload.append(0x00)
        payload.append(contentsOf: Array(inviteCode.utf8))

        let encoded = base32Encode(payload)
        return insertDashes(encoded)
    }

    // MARK: - Base32

    private static func base32Encode(_ data: Data) -> String {
        var result = ""
        var buffer = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                let idx = (buffer >> bitsLeft) & 0x1F
                result.append(charset[idx])
            }
        }

        if bitsLeft > 0 {
            let idx = (buffer << (5 - bitsLeft)) & 0x1F
            result.append(charset[idx])
        }

        return result
    }

    private static func base32Decode(_ s: String) -> Data? {
        var lookup = [Character: Int]()
        for (i, c) in charset.enumerated() {
            lookup[c] = i
        }

        var result = Data()
        var buffer = 0
        var bitsLeft = 0

        for c in s {
            guard let val = lookup[c] else { return nil }
            buffer = (buffer << 5) | val
            bitsLeft += 5
            if bitsLeft >= 8 {
                bitsLeft -= 8
                result.append(UInt8((buffer >> bitsLeft) & 0xFF))
            }
        }

        return result
    }

    private static func insertDashes(_ s: String) -> String {
        var parts = [String]()
        var start = s.startIndex
        while start < s.endIndex {
            let end = s.index(start, offsetBy: dashEvery, limitedBy: s.endIndex) ?? s.endIndex
            parts.append(String(s[start..<end]))
            start = end
        }
        return parts.joined(separator: "-")
    }
}
