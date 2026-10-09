import Foundation

/// Minimal JSON:API client for Planning Center Services using a Personal Access Token.
/// Create one at https://api.planningcenteronline.com/oauth/applications → "Personal Access Tokens".
struct PlanningCenterClient {
    var appID: String
    var secret: String

    enum PCOError: LocalizedError {
        case notConfigured, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Add your Planning Center Application ID and Secret in Settings → Planning Center."
            case .http(let c, let s): "Planning Center returned \(c): \(s)"
            }
        }
    }

    struct Resource {
        var id: String
        var type: String
        var attributes: [String: Any]
        var relationships: [String: Any]

        func string(_ k: String) -> String? { attributes[k] as? String }
        func relID(_ k: String) -> String? {
            ((relationships[k] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
        }
    }

    struct Page {
        var data: [Resource]
        var included: [Resource]
    }

    private static func resource(_ d: [String: Any]) -> Resource? {
        guard let id = d["id"] as? String, let type = d["type"] as? String else { return nil }
        return Resource(id: id, type: type, attributes: d["attributes"] as? [String: Any] ?? [:],
                        relationships: d["relationships"] as? [String: Any] ?? [:])
    }

    /// GETs a path and follows `links.next` to collect every page.
    func getAll(_ path: String, query: [URLQueryItem] = []) async throws -> Page {
        guard !appID.isEmpty, !secret.isEmpty else { throw PCOError.notConfigured }
        var c = URLComponents(string: "https://api.planningcenteronline.com/services/v2/\(path)")!
        c.queryItems = query.isEmpty ? nil : query
        var next: URL? = c.url
        var page = Page(data: [], included: [])
        let auth = Data("\(appID):\(secret)".utf8).base64EncodedString()
        var guardCount = 0
        while let url = next, guardCount < 30 {
            guardCount += 1
            var r = URLRequest(url: url)
            r.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 {
                // Rate limited: PCO allows 100 requests / 20s. Back off and retry.
                let wait = Double((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
                try await Task.sleep(for: .seconds(wait))
                continue
            }
            guard (200..<300).contains(code) else {
                throw PCOError.http(code, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if let arr = json["data"] as? [[String: Any]] { page.data += arr.compactMap(Self.resource) }
            else if let one = json["data"] as? [String: Any], let r = Self.resource(one) { page.data.append(r) }
            if let inc = json["included"] as? [[String: Any]] { page.included += inc.compactMap(Self.resource) }
            next = ((json["links"] as? [String: Any])?["next"] as? String).flatMap(URL.init(string:))
        }
        return page
    }

    func serviceTypes() async throws -> [(id: String, name: String)] {
        try await getAll("service_types", query: [URLQueryItem(name: "per_page", value: "100")]).data
            .map { ($0.id, $0.string("name") ?? $0.id) }
    }

    /// How many future plans a service type has (the real "Sunday Morning" is the one with plans coming up).
    func upcomingPlanCount(serviceType: String) async throws -> Int {
        guard !appID.isEmpty, !secret.isEmpty else { throw PCOError.notConfigured }
        var c = URLComponents(string: "https://api.planningcenteronline.com/services/v2/service_types/\(serviceType)/plans")!
        c.queryItems = [URLQueryItem(name: "filter", value: "future"), URLQueryItem(name: "per_page", value: "1")]
        var r = URLRequest(url: c.url!, timeoutInterval: 15)
        r.setValue("Basic " + Data("\(appID):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw PCOError.http(code, "") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["meta"] as? [String: Any])?["total_count"] as? Int ?? 0
    }

    func plans(serviceType: String, from: Date, days: Int) async throws -> [Resource] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let start = Calendar.current.date(byAdding: .day, value: -1, to: from)!
        let end = Calendar.current.date(byAdding: .day, value: days, to: from)!
        let plans = try await getAll("service_types/\(serviceType)/plans", query: [
            URLQueryItem(name: "filter", value: "after"),
            URLQueryItem(name: "after", value: f.string(from: start)),
            URLQueryItem(name: "order", value: "sort_date"),
            URLQueryItem(name: "per_page", value: "50"),
        ]).data
        let iso = ISO8601DateFormatter()
        return plans.filter { p in
            guard let s = p.string("sort_date"), let d = iso.date(from: s) else { return true }
            return d <= end
        }
    }

    func items(serviceType: String, plan: String) async throws -> Page {
        try await getAll("service_types/\(serviceType)/plans/\(plan)/items", query: [
            URLQueryItem(name: "include", value: "song,arrangement"),
            URLQueryItem(name: "per_page", value: "100"),
        ])
    }
}
