//
// CorrectionService.swift
// Spling
//
// Posts accuracy corrections — what was ordered against what actually arrived.
//
// This is the third pillar. Cross-language composition and portable profiles
// both fail quietly if nobody is measuring whether the order came out right,
// and the ledger can only measure what it is told. A correction that says
// "something was wrong" and nothing else is a row that cannot be attributed to
// a merchant, a location, an item or a modifier, which means it improves
// nothing for the next person.
//
// So this service refuses to post one. Validation here is not input hygiene;
// it is the difference between a ledger and a complaints box.
//
import Foundation

enum CorrectionError: LocalizedError {
    case needsItem
    case needsDetail(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .needsItem:
            return "Pick which item this is about, so we can tell the business exactly what to fix."
        case .needsDetail(let prompt):
            return prompt
        case .networkError(let m):
            return "Network error: \(m)"
        }
    }
}

actor CorrectionService {
    static let shared = CorrectionService()
    private init() {}

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Local validation, run before anything leaves the device.
    ///
    /// The rule: a correction must name what went wrong specifically enough to
    /// be attributed. Everything except `.other` has to name the line it is
    /// about, and everything except `.missingItem` has to say what arrived —
    /// "missing" needs no "instead", because nothing came.
    nonisolated func validate(_ c: Correction) throws {
        if c.kind != .other, c.itemName == nil {
            throw CorrectionError.needsItem
        }
        if c.kind.requiresReceived, c.received == nil {
            throw CorrectionError.needsDetail(c.kind.receivedPrompt)
        }
        if c.kind == .other, c.note == nil {
            throw CorrectionError.needsDetail(c.kind.receivedPrompt)
        }
    }

    /// Sends a correction. Same field contract as the connector's
    /// `submit_correction` tool, so the app rail and the assistant rail land in
    /// one ledger rather than two half-populated ones.
    @discardableResult
    func submit(_ correction: Correction) async throws -> Correction {
        try validate(correction)

        guard let url = URL(string: "\(AppConfig.API.baseURL)\(AppConfig.API.correctionsEndpoint)") else {
            throw CorrectionError.networkError("Invalid corrections endpoint URL.")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(correction)
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw CorrectionError.networkError("No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw CorrectionError.networkError("HTTP \(http.statusCode)")
        }
        // The server may normalise or enrich the row; if it hands nothing back,
        // what we sent is still what was recorded.
        return (try? decoder.decode(Correction.self, from: data)) ?? correction
    }

    /// Corrections already filed against one order, so the UI can avoid asking
    /// a person to report the same failure twice.
    func fetch(orderID: UUID) async throws -> [Correction] {
        guard let url = URL(
            string: "\(AppConfig.API.baseURL)\(AppConfig.API.correctionsEndpoint)/order/\(orderID.uuidString)"
        ) else {
            throw CorrectionError.networkError("Invalid URL")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode([Correction].self, from: data)
    }
}
