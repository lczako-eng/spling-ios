//
// POSService.swift
// Spling
//
// Routes confirmed orders to the vendor's POS system via webhook,
// polls for queue position, and fetches real-time queue status.
//
import Foundation

enum POSError: LocalizedError {
    case notConfigured
    case rejected(String)
    case timeout
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:        return "POS system is not configured for this vendor."
        case .rejected(let msg):    return "Order rejected by POS: \(msg)"
        case .timeout:              return "POS system did not respond in time. Please check with staff."
        case .networkError(let m):  return "Network error reaching POS: \(m)"
        }
    }
}

actor POSService {
    static let shared = POSService()
    private init() {}

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Submit Order to POS

    /// Sends the Spling order to the vendor's POS webhook and returns the acknowledgement.
    /// If the vendor requires acknowledgement, waits up to 30 s for confirmation.
    func submit(
        order: Order,
        paymentTransactionID: String,
        posInfo: POSSystemInfo
    ) async throws -> POSAcknowledgement {

        let payload = buildPOSPayload(order: order, paymentTransactionID: paymentTransactionID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var req = URLRequest(url: posInfo.endpointURL)
        req.httpMethod = "POST"
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.setValue("Spling-iOS/1.0",    forHTTPHeaderField: "User-Agent")
        req.httpBody      = try encoder.encode(payload)
        req.timeoutInterval = posInfo.requiresAcknowledgement ? 30 : 10

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw POSError.networkError("No HTTP response")
            }
            switch http.statusCode {
            case 200...299:
                return try decoder.decode(POSAcknowledgement.self, from: data)
            case 422:
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "Validation error"
                throw POSError.rejected(msg)
            default:
                throw POSError.networkError("HTTP \(http.statusCode)")
            }
        } catch let error as POSError { throw error }
        catch let urlError as URLError where urlError.code == .timedOut {
            throw POSError.timeout
        }
        catch { throw POSError.networkError(error.localizedDescription) }
    }

    // MARK: - Queue Status

    /// Fetches the current queue position for a placed order.
    func fetchQueueStatus(queueID: String) async throws -> QueueStatus {
        guard let url = URL(string: "\(AppConfig.API.baseURL)\(AppConfig.API.queueEndpoint)/\(queueID)") else {
            throw POSError.notConfigured
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(QueueStatus.self, from: data)
    }

    // MARK: - Helpers

    private func buildPOSPayload(order: Order, paymentTransactionID: String) -> POSOrderPayload {
        let lines = order.items.map { item in
            POSOrderLine(
                posItemID:           item.menuItem.id,
                name:                item.menuItem.name,
                quantity:            item.quantity,
                unitPriceCents:      item.menuItem.priceCents,
                modifiers:           Array(item.selectedCustomizations.values),
                specialInstructions: item.specialInstructions
            )
        }
        return POSOrderPayload(
            splingOrderID:            order.id,
            terminalID:               order.terminalID ?? "unknown",
            items:                    lines,
            totalCents:               order.totalCents,
            paymentTransactionID:     paymentTransactionID,
            channel:                  order.channel,
            placedByCaretaker:        order.placedByCaretaker,
            customerFacingReference:  generatePickupCode(),
            timestamp:                Date()
        )
    }

    /// Generates a short, human-readable pickup code (e.g. "SPL-4B2F").
    private func generatePickupCode() -> String {
        let chars  = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        let random = (0..<4).map { _ in chars.randomElement()! }
        return "SPL-" + String(random)
    }
}
