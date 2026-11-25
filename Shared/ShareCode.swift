import Foundation

enum CodeError: Error { case invalid }

enum ShareCode {
    static let fileExtension = "solocheckin"

    static func encode(_ rule: DailyRule, includeZone: Bool = true) -> String {
        let time = String(format: "%02d%02d", rule.hour, rule.minute)
        let zone = includeZone ? Data(rule.zoneID.utf8).base64EncodedString() : ""
        return "SCI1:\(time):\(rule.grace):\(zone)"
    }

    static func decode(_ text: String, localZone: TimeZone = .current) throws -> DailyRule {
        guard text.utf8.count <= 512 else { throw CodeError.invalid }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "SCI1", fields[1].utf8.count == 4, number(fields[1]), number(fields[2]),
              let hour = Int(fields[1].prefix(2)), let minute = Int(fields[1].suffix(2)),
              let grace = Int(fields[2]) else { throw CodeError.invalid }
        let zone: String
        if fields[3].isEmpty {
            zone = localZone.identifier
        } else {
            guard let data = Data(base64Encoded: String(fields[3])),
                  data.base64EncodedString() == String(fields[3]),
                  let value = String(data: data, encoding: .utf8) else { throw CodeError.invalid }
            zone = value
        }
        let rule = DailyRule(hour: hour, minute: minute, grace: grace, zoneID: zone)
        guard rule.valid else { throw CodeError.invalid }
        return rule
    }

    private static func number(_ field: Substring) -> Bool {
        !field.isEmpty && field.utf8.allSatisfy { (48...57).contains($0) }
    }
}
