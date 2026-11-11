import Foundation
import AppKit

struct QuotaWindow: Identifiable, Codable {
    var id = UUID()
    let label: String
    let pct: Double
    let reset: Date?

    private enum CodingKeys: String, CodingKey { case label, pct, reset }

    init(label: String, pct: Double, reset: Date?) {
        self.label = label; self.pct = pct; self.reset = reset
    }

    /// Display name without the word "models": "Gemini Models · weekly" -> "Gemini · weekly".
    var title: String {
        label.replacingOccurrences(of: " models", with: "", options: .caseInsensitive)
    }

    /// False once the window's reset time has passed (a cached percentage no longer applies).
    var isCurrent: Bool { reset.map { $0 > Date() } ?? true }

    var color: NSColor {
        pct >= 90 ? NSColor(red: 0.90, green: 0.28, blue: 0.30, alpha: 1)
            : pct >= 70 ? NSColor(red: 0.94, green: 0.69, blue: 0.24, alpha: 1)
            : NSColor(red: 0.27, green: 0.47, blue: 0.85, alpha: 1)
    }

    /// Short form for the menu: "1h", "3d", "45m".
    var resetShort: String {
        guard let reset else { return "?" }
        let secs = reset.timeIntervalSinceNow
        if secs <= 0 { return "now" }
        let h = Int(secs) / 3600, m = Int(secs) % 3600 / 60
        return h >= 24 ? "\(h / 24)d" : h > 0 ? "\(h)h" : "\(max(m, 1))m"
    }
}

/// "just now", "12m ago", "3h ago", "2d ago"
func ago(_ date: Date) -> String {
    let m = Int(-date.timeIntervalSinceNow / 60)
    return m < 1 ? "just now" : m < 60 ? "\(m)m ago" : m < 1440 ? "\(m / 60)h ago" : "\(m / 1440)d ago"
}

struct FetchResult {
    let windows: [QuotaWindow]
}

struct ProviderState: Identifiable {
    let id: String          // provider name
    var windows: [QuotaWindow] = []
    var error: String?
    var closed = false
    var lastGood: Date?

    var isStale: Bool { error != nil && !windows.isEmpty }
}

enum ProviderError: LocalizedError {
    case notRunning
    case rateLimited
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Not running"
        case .rateLimited: return "Rate limited - retrying shortly"
        case .message(let m): return m
        }
    }
}
