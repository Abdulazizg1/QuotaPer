import Foundation

// MARK: - helpers

private let home = FileManager.default.homeDirectoryForCurrentUser

private func parseISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

private func num(_ v: Any?) -> Double? {
    switch v {
    case let n as NSNumber: return n.doubleValue
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let s as String: return Double(s)
    default: return nil
    }
}

private func runProcess(_ path: String, _ args: [String], timeout: TimeInterval = 15) async -> (out: String, status: Int32) {
    await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return ("", -1) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                p.terminationStatus)
    }.value
}

/// No URL cache: every response is read once and dropped.
private let session: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.urlCache = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: c)
}()

private func getJSON(_ req: URLRequest) async throws -> [String: Any] {
    let (data, resp) = try await session.data(for: req)
    if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
        if http.statusCode == 429 { throw ProviderError.rateLimited }
        throw ProviderError.message("HTTP \(http.statusCode)")
    }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func request(_ url: String, headers: [String: String], body: Data? = nil, timeout: TimeInterval = 10) -> URLRequest {
    var r = URLRequest(url: URL(string: url)!, timeoutInterval: timeout)
    if let body { r.httpMethod = "POST"; r.httpBody = body }
    for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
    return r
}

// MARK: - Claude

func fetchClaude() async throws -> FetchResult {
    let (raw, _) = await runProcess("/usr/bin/security",
        ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    guard !raw.isEmpty,
          let creds = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
          let oauth = creds["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String
    else { throw ProviderError.message("No Claude Code login in Keychain") }

    let d: [String: Any]
    do {
        d = try await getJSON(request("https://api.anthropic.com/api/oauth/usage", headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "quotaper/1.0",
        ]))
    } catch ProviderError.message("HTTP 401") {
        throw ProviderError.message("Token expired - open Claude Code once to refresh")
    }

    var out: [QuotaWindow] = []
    for (key, label) in [("five_hour", "5-hour limit"), ("seven_day", "Weekly · all models")] {
        if let w = d[key] as? [String: Any], let u = num(w["utilization"]) {
            out.append(QuotaWindow(label: label, pct: u, reset: parseISO(w["resets_at"] as? String)))
        }
    }
    for lim in (d["limits"] as? [[String: Any]]) ?? [] where lim["kind"] as? String == "weekly_scoped" {
        let model = ((lim["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
        if let model, let p = num(lim["percent"]) {
            out.append(QuotaWindow(label: "Weekly · \(model)", pct: p, reset: parseISO(lim["resets_at"] as? String)))
        }
    }
    return FetchResult(windows: out)
}

// MARK: - ChatGPT (Codex login)

func fetchChatGPT() async throws -> FetchResult {
    let url = home.appendingPathComponent(".codex/auth.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let t = json["tokens"] as? [String: Any],
          let access = t["access_token"] as? String,
          let account = t["account_id"] as? String
    else { throw ProviderError.message("No Codex login found (~/.codex/auth.json)") }

    let d: [String: Any]
    do {
        d = try await getJSON(request("https://chatgpt.com/backend-api/wham/usage", headers: [
            "Authorization": "Bearer \(access)",
            "ChatGPT-Account-Id": account,
            "User-Agent": "quotaper/1.0",
        ]))
    } catch ProviderError.message(let m) where m == "HTTP 401" || m == "HTTP 403" {
        throw ProviderError.message("Token expired - open Codex once to refresh")
    }

    var out: [QuotaWindow] = []
    let rl = d["rate_limit"] as? [String: Any]
    for key in ["primary_window", "secondary_window"] {
        guard let w = rl?[key] as? [String: Any],
              let secs = num(w["limit_window_seconds"]),
              let used = num(w["used_percent"]) else { continue }
        let reset = num(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
        out.append(QuotaWindow(label: secs / 3600 <= 24 ? "5-hour limit" : "Weekly · all models", pct: used, reset: reset))
    }
    return FetchResult(windows: out)
}

// MARK: - Antigravity

/// Turns Antigravity's quota groups into windows. The local server and the `agy` CLI return the same
/// structure with different key names.
private func windows(from groups: [[String: Any]], nameKey: String, idKey: String,
                     remainingKey: String, resetKey: String) -> [QuotaWindow] {
    var out: [QuotaWindow] = []
    for g in groups {
        let gname = g[nameKey] as? String ?? ""
        for b in (g["buckets"] as? [[String: Any]]) ?? [] {
            if b["disabled"] as? Bool == true { continue }
            guard let remaining = num(b[remainingKey]) else { continue }
            let win = (b["window"] as? String) ?? (b[idKey] as? String) ?? "?"
            out.append(QuotaWindow(label: "\(gname) · \(win)",
                                   pct: (1 - remaining) * 100,
                                   reset: parseISO(b[resetKey] as? String)))
        }
    }
    return out.sorted { $0.pct > $1.pct }
}

// Open: the local language server (written by the Antigravity app or Gemini's helper).

private struct Hub { let port: Int; let csrf: String }

/// Newest hub file whose process is still alive.
private func findHub() -> Hub? {
    let dir = home.appendingPathComponent(".gemini/antigravity/daemon")
    let files = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let hubs = files
        .filter { $0.lastPathComponent.hasPrefix("hub_") && $0.pathExtension == "json" }
        .sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    for f in hubs {
        guard let data = try? Data(contentsOf: f),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = info["pid"] as? Int,
              let port = info["httpPort"] as? Int,
              let csrf = info["csrfToken"] as? String else { continue }
        if kill(pid_t(pid), 0) == 0 { return Hub(port: port, csrf: csrf) }
    }
    return nil
}

private func queryHub(_ hub: Hub) async -> FetchResult? {
    guard let d = try? await getJSON(request(
        "http://127.0.0.1:\(hub.port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
        headers: ["Content-Type": "application/json", "x-codeium-csrf-token": hub.csrf],
        body: Data("{}".utf8), timeout: 5)) else { return nil }   // stale hub file / dead port

    let root = (d["response"] as? [String: Any]) ?? d
    let out = windows(from: (root["groups"] as? [[String: Any]]) ?? [], nameKey: "displayName",
                      idKey: "bucketId", remainingKey: "remainingFraction", resetKey: "resetTime")
    return out.isEmpty ? nil : FetchResult(windows: out)
}

// Closed: ask the `agy` CLI.

private var lastCLI: (date: Date, result: FetchResult)?
private let cliInterval: TimeInterval = 60   // spawning agy costs ~0.5 s of CPU; once per poll at most

private func agyPath() -> String? {
    [home.appendingPathComponent(".local/bin/agy").path,
     home.appendingPathComponent(".gemini/antigravity-cli/bin/agy").path,
     "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Parses the output of `agy --print /usage --output-format json`.
private func parseUsage(_ text: String) -> FetchResult? {
    guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          root["status"] as? String == "SUCCESS",
          let data = (root["command"] as? [String: Any])?["data"] as? [String: Any],
          let groups = data["groups"] as? [[String: Any]] else { return nil }
    let out = windows(from: groups, nameKey: "name", idKey: "id",
                      remainingKey: "remaining_fraction", resetKey: "reset_time")
    return out.isEmpty ? nil : FetchResult(windows: out)
}

func fetchAntigravity() async throws -> FetchResult {
    // 1. Antigravity (or Gemini) is open: ask its local server directly - instant.
    if let hub = findHub(), let live = await queryHub(hub) { return live }

    // 2. Closed: ask the `agy` CLI, which reads the same account quota online (a few seconds, no app).
    if let c = lastCLI, Date().timeIntervalSince(c.date) < cliInterval { return c.result }
    guard let agy = agyPath() else { throw ProviderError.notRunning }
    let (out, status) = await runProcess(agy, ["--print", "/usage", "--output-format", "json"], timeout: 25)
    guard status == 0, let result = parseUsage(out) else {
        throw ProviderError.message("Couldn't read Antigravity usage (agy)")
    }
    lastCLI = (Date(), result)
    return result
}
