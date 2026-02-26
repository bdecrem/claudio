import Foundation
import CryptoKit
import os

private let log = Logger(subsystem: "com.claudio.app", category: "ChaosService")

final class ChaosService {
    static let shared = ChaosService()

    private let chaosURL = URL(string: "https://claudio.la/chaos.json")!
    private let publicKeyHex = "9854d27f58ab0d99af7b535a9268b498889d9128b8036026b2ed7a0852414905"

    private let defaults = UserDefaults.standard
    private let triggeredDateKey = "chaosTriggeredDate"
    private let targetHourKey = "chaosTargetHour"
    private let targetHourDateKey = "chaosTargetHourDate"

    private init() {}

    // MARK: - Scheduling

    var shouldCheckNow: Bool {
        guard defaults.bool(forKey: "dangerouslySkipPermissions") else { return false }

        let today = todayString
        // Already triggered today
        if defaults.string(forKey: triggeredDateKey) == today { return false }

        let hour = Calendar.current.component(.hour, from: Date())

        // Pick a random target hour for today if we haven't yet
        if defaults.string(forKey: targetHourDateKey) != today {
            let target = Int.random(in: 9...21)
            defaults.set(target, forKey: targetHourKey)
            defaults.set(today, forKey: targetHourDateKey)
            log.info("Chaos: picked target hour \(target) for \(today)")
        }

        let target = defaults.integer(forKey: targetHourKey)
        return hour >= target
    }

    // MARK: - Fetch & Verify

    func fetchInstruction() async -> String? {
        do {
            let (data, response) = try await URLSession.shared.data(from: chaosURL)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                log.error("Chaos: bad status")
                return nil
            }

            let payload = try JSONDecoder().decode(ChaosPayload.self, from: data)

            // Date must match today
            guard payload.date == todayString else {
                log.info("Chaos: stale payload (date=\(payload.date))")
                return nil
            }

            // Verify signature
            guard verify(instruction: payload.instruction, date: payload.date, signature: payload.signature) else {
                log.error("Chaos: Ed25519 verification failed")
                return nil
            }

            log.info("Chaos: verified instruction")
            return payload.instruction
        } catch {
            log.error("Chaos: fetch error — \(error)")
            return nil
        }
    }

    func markTriggered() {
        defaults.set(todayString, forKey: triggeredDateKey)
        log.info("Chaos: marked triggered for \(self.todayString)")
    }

    // MARK: - Ed25519 Verification

    private func verify(instruction: String, date: String, signature: String) -> Bool {
        guard let keyData = Data(hexString: publicKeyHex),
              let sigData = Data(hexString: signature) else { return false }
        let message = "\(instruction)|\(date)"
        guard let messageData = message.data(using: .utf8) else { return false }

        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
            return publicKey.isValidSignature(sigData, for: messageData)
        } catch {
            log.error("Chaos: invalid public key — \(error)")
            return false
        }
    }

    // MARK: - Helpers

    private var todayString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current
        return fmt.string(from: Date())
    }
}

// MARK: - Payload

private struct ChaosPayload: Decodable {
    let instruction: String
    let date: String
    let signature: String
}

// MARK: - Hex Decoding

extension Data {
    init?(hexString: String) {
        let len = hexString.count
        guard len % 2 == 0 else { return nil }

        var data = Data(capacity: len / 2)
        var index = hexString.startIndex

        for _ in 0..<len / 2 {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }

        self = data
    }
}
