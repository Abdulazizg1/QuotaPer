import Foundation
import Combine

@MainActor
final class QuotaStore: ObservableObject {
    @Published var states: [ProviderState] = [
        ProviderState(id: "Claude"),
        ProviderState(id: "ChatGPT"),
        ProviderState(id: "Antigravity"),
    ]
    @Published var lastUpdate: Date?
    @Published var refreshing = false

    private let fetchers: [String: () async throws -> FetchResult] = [
        "Claude": fetchClaude,
        "ChatGPT": fetchChatGPT,
        "Antigravity": fetchAntigravity,
    ]

    // Seconds between fetches for every provider (the cloud endpoints rate-limit aggressively).
    private let interval: TimeInterval = 60
    private var nextAllowed: [String: Date] = [:]
    private var backoff: [String: TimeInterval] = [:]

    /// Ring fill: the main usage of the first provider that has data (Claude, then ChatGPT, ...).
    var iconProgress: Double? {
        states.compactMap { $0.windows.first?.pct }.first.map { $0 / 100 }
    }

    private struct Cached: Codable {
        var windows: [QuotaWindow]
        var at: Date
    }

    private func loadCache(_ name: String) -> Cached? {
        UserDefaults.standard.data(forKey: "cache.\(name)")
            .flatMap { try? JSONDecoder().decode(Cached.self, from: $0) }
    }

    private func saveCache(_ name: String, _ r: FetchResult) {
        let c = Cached(windows: r.windows, at: Date())
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: "cache.\(name)") }
    }

    init(autoRefresh: Bool = true) {
        // Show the last known values immediately (and keep them when a provider is closed or offline).
        for i in states.indices {
            if let c = loadCache(states[i].id) {
                states[i].windows = c.windows.filter(\.isCurrent)
                states[i].lastGood = c.at
            }
        }
        guard autoRefresh else { return }
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            }
        }
    }

    func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        await withTaskGroup(of: Void.self) { group in
            for (name, fetch) in fetchers {
                if !force, let t = nextAllowed[name], t > Date() { continue }
                group.addTask { [self] in
                    let result: Result<FetchResult, Error>
                    do { result = .success(try await fetch()) }
                    catch { result = .failure(error) }
                    await apply(name, result)
                }
            }
            await group.waitForAll()
        }
        lastUpdate = Date()
    }

    private func apply(_ name: String, _ result: Result<FetchResult, Error>) {
        guard let i = states.firstIndex(where: { $0.id == name }) else { return }
        switch result {
        case .success(let r):
            states[i].windows = r.windows
            states[i].error = nil
            states[i].closed = false
            states[i].lastGood = Date()
            saveCache(name, r)
            backoff[name] = nil
            nextAllowed[name] = Date().addingTimeInterval(interval)
        case .failure(let e):
            if case ProviderError.notRunning = e {
                // Provider app is closed: keep showing its last known (still current) quotas.
                states[i].windows = loadCache(name)?.windows.filter(\.isCurrent) ?? []
                states[i].error = nil
                states[i].closed = true
            } else {
                if case ProviderError.rateLimited = e {
                    let b = min((backoff[name] ?? 60) * 2, 900)   // 2m, 4m ... capped at 15m
                    backoff[name] = b
                    nextAllowed[name] = Date().addingTimeInterval(b)
                } else {
                    nextAllowed[name] = Date().addingTimeInterval(interval)
                }
                states[i].error = e.localizedDescription   // keep last good windows (shown as stale)
                states[i].closed = false
            }
        }
    }
}
