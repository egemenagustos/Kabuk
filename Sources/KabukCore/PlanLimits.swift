import Foundation

/// One rate-limit window of a Claude or Codex subscription.
public struct LimitWindow: Codable, Equatable, Sendable {
    /// 0–100, above 100 once the limit is exceeded.
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// How far through a window of this length the clock is, 0…1. Usage ahead of it runs out
    /// before the reset at this pace.
    public func elapsed(of length: TimeInterval, at now: Date = Date()) -> Double? {
        guard let resetsAt else { return nil }
        return min(max(1 - resetsAt.timeIntervalSince(now) / length, 0), 1)
    }
}

/// How much of the plan's 5-hour and weekly limits an agent has used.
public struct PlanLimits: Codable, Equatable, Sendable {
    public var fiveHour: LimitWindow?
    public var weekly: LimitWindow?
    public var updatedAt: Date

    public static let fiveHourLength: TimeInterval = 5 * 3600
    public static let weeklyLength: TimeInterval = 7 * 86400

    public init(fiveHour: LimitWindow? = nil, weekly: LimitWindow? = nil, updatedAt: Date = Date()) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.updatedAt = updatedAt
    }

    /// A window whose reset time has passed starts again from zero, so old numbers don't linger.
    public func current(at now: Date = Date()) -> PlanLimits {
        func fresh(_ window: LimitWindow?) -> LimitWindow? {
            guard let window, let resetsAt = window.resetsAt, resetsAt <= now else { return window }
            return LimitWindow(usedPercent: 0, resetsAt: nil)
        }
        return PlanLimits(fiveHour: fresh(fiveHour), weekly: fresh(weekly), updatedAt: updatedAt)
    }

    /// Same numbers, ignoring when they were read.
    public func sameUsage(as other: PlanLimits) -> Bool {
        fiveHour == other.fiveHour && weekly == other.weekly
    }

    /// Reads `rate_limits` from the JSON Claude Code gives its status line command:
    /// `{"five_hour": {"used_percentage": 68, "resets_at": 1792189760}, "seven_day": {…}}`.
    public static func fromClaudeStatusLine(_ data: Data, now: Date = Date()) -> PlanLimits? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let limits = json["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> LimitWindow? {
            guard let entry = limits[key] as? [String: Any], let used = double(entry["used_percentage"]) else { return nil }
            return LimitWindow(usedPercent: used, resetsAt: double(entry["resets_at"]).map(Date.init(timeIntervalSince1970:)))
        }
        let result = PlanLimits(fiveHour: window("five_hour"), weekly: window("seven_day"), updatedAt: now)
        return result.fiveHour == nil && result.weekly == nil ? nil : result
    }

    /// Reads a Codex rollout (JSONL); the last `token_count` event carrying `rate_limits` has the
    /// plan's windows as `primary` and `secondary`, told apart by `window_minutes`.
    public static func fromCodexRollout(_ data: Data, now: Date = Date()) -> PlanLimits? {
        let marker = Data(#""rate_limits""#.utf8)
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.range(of: marker) != nil {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let payload = entry["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            var result = PlanLimits(updatedAt: now)
            for key in ["primary", "secondary"] {
                guard let entry = limits[key] as? [String: Any], let used = double(entry["used_percent"]) else { continue }
                let window = LimitWindow(usedPercent: used, resetsAt: double(entry["resets_at"]).map(Date.init(timeIntervalSince1970:)))
                switch double(entry["window_minutes"]) {
                case 300: result.fiveHour = window
                case 10080: result.weekly = window
                default: break
                }
            }
            if result.fiveHour != nil || result.weekly != nil { return result }
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
