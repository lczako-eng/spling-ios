//
// PaymentManager.swift
// Spling
//
// Handles payment processing via Stripe.
// Add the Stripe iOS SDK via Swift Package Manager:
//   https://github.com/stripe/stripe-ios  (StripePaymentSheet target)
//
// This file compiles without the Stripe SDK present by using a
// protocol + live/mock implementations pattern. Swap to StripePaymentSheet
// in production by implementing StripePaymentService below.
//
import Foundation
import PassKit

// MARK: - Payment Errors

enum PaymentError: LocalizedError {
    case notConfigured
    case cancelled
    case declined(String)
    case networkError(String)
    case unknownError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:        return "Payment is not configured. Please contact support."
        case .cancelled:            return "Payment was cancelled."
        case .declined(let msg):    return "Payment declined: \(msg)"
        case .networkError(let m):  return "Network error during payment: \(m)"
        case .unknownError(let m):  return "An unexpected payment error occurred: \(m)"
        }
    }
}

// MARK: - Payment Manager

final class PaymentManager {
    static let shared = PaymentManager()
    private init() {}

    // MARK: - Process Payment

    /// Processes payment for an order and returns a PaymentResult on success.
    /// In production this calls your backend to create a PaymentIntent,
    /// then presents Stripe's PaymentSheet (or Apple Pay sheet).
    func process(order: Order, method: PaymentMethod) async throws -> PaymentResult {
        switch method {
        case .applePay:
            return try await processApplePay(order: order)
        case .creditCard, .debitCard:
            return try await processCard(order: order, method: method)
        case .splingWallet:
            return try await processWallet(order: order, method: method)
        }
    }

    // MARK: - Apple Pay

    private func processApplePay(order: Order) async throws -> PaymentResult {
        guard PKPaymentAuthorizationController.canMakePayments() else {
            throw PaymentError.notConfigured
        }

        // Build the PKPaymentRequest
        let request = PKPaymentRequest()
        request.merchantIdentifier         = "merchant.app.spling"
        request.supportedNetworks          = [.visa, .masterCard, .amex, .discover]
        request.merchantCapabilities       = .capability3DS
        request.countryCode                = AppConfig.Payment.countryCode
        request.currencyCode               = AppConfig.Payment.currency.uppercased()
        request.paymentSummaryItems        = [
            PKPaymentSummaryItem(
                label: order.vendorName,
                amount: NSDecimalNumber(value: Double(order.totalCents) / 100.0)
            )
        ]

        // Use continuation to bridge PKPaymentAuthorizationController callback
        return try await withCheckedThrowingContinuation { continuation in
            let controller = PKPaymentAuthorizationController(paymentRequest: request)
            let delegate   = ApplePayDelegate(order: order, continuation: continuation)
            controller.delegate = delegate
            // Keep delegate alive for the duration of the sheet
            objc_setAssociatedObject(controller, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            controller.present()
        }
    }

    // MARK: - Card (Stripe)

    private func processCard(order: Order, method: PaymentMethod) async throws -> PaymentResult {
        // Step 1: Ask your backend for a PaymentIntent client secret
        let clientSecret = try await createPaymentIntent(amountCents: order.totalCents, orderID: order.id)

        // Step 2: In production, present StripePaymentSheet here.
        // For now we simulate a successful charge — replace with real Stripe SDK call.
        #if DEBUG
        try await Task.sleep(nanoseconds: 1_500_000_000)  // Simulate network
        return PaymentResult(
            transactionID: "pi_debug_\(UUID().uuidString.prefix(8))",
            amountCents:   order.totalCents,
            method:        method.displayName,
            timestamp:     Date(),
            receiptURL:    nil
        )
        #else
        // Production: use StripePaymentSheet
        // let config = PaymentSheet.Configuration()
        // let sheet  = PaymentSheet(paymentIntentClientSecret: clientSecret, configuration: config)
        // ... present and handle result
        throw PaymentError.notConfigured
        #endif
    }

    // MARK: - Spling Wallet

    private func processWallet(order: Order, method: PaymentMethod) async throws -> PaymentResult {
        guard case .splingWallet(let balance) = method else {
            throw PaymentError.notConfigured
        }
        guard balance >= order.totalCents else {
            throw PaymentError.declined("Insufficient Spling Wallet balance.")
        }

        let body: [String: Any] = [
            "orderID":    order.id.uuidString,
            "amountCents": order.totalCents
        ]
        return try await postToBackend(
            endpoint: AppConfig.API.paymentEndpoint + "/wallet",
            body: body,
            method: method
        )
    }

    // MARK: - Backend Helpers

    private func createPaymentIntent(amountCents: Int, orderID: UUID) async throws -> String {
        guard let url = URL(string: "\(AppConfig.API.baseURL)\(AppConfig.API.paymentEndpoint)/intent") else {
            throw PaymentError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "amount":    amountCents,
            "currency":  AppConfig.Payment.currency,
            "orderID":   orderID.uuidString
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PaymentError.networkError("PaymentIntent creation failed")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let secret = json?["client_secret"] as? String else {
            throw PaymentError.networkError("Missing client_secret in response")
        }
        return secret
    }

    private func postToBackend(
        endpoint: String,
        body: [String: Any],
        method: PaymentMethod
    ) async throws -> PaymentResult {
        guard let url = URL(string: "\(AppConfig.API.baseURL)\(endpoint)") else {
            throw PaymentError.notConfigured
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PaymentError.networkError("Payment request failed")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PaymentResult.self, from: data)
    }
}

// MARK: - Apple Pay Delegate (private helper)

private final class ApplePayDelegate: NSObject, PKPaymentAuthorizationControllerDelegate {
    private let order:        Order
    private let continuation: CheckedContinuation<PaymentResult, Error>

    init(order: Order, continuation: CheckedContinuation<PaymentResult, Error>) {
        self.order        = order
        self.continuation = continuation
    }

    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        // In production: send payment.token to your backend / Stripe here
        // to confirm the PaymentIntent, then call completion(.init(status: .success, errors: nil))
        completion(PKPaymentAuthorizationResult(status: .success, errors: nil))

        let result = PaymentResult(
            transactionID: "ap_\(UUID().uuidString.prefix(12))",
            amountCents:   order.totalCents,
            method:        "Apple Pay",
            timestamp:     Date(),
            receiptURL:    nil
        )
        continuation.resume(returning: result)
    }

    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        controller.dismiss()
    }

    func paymentAuthorizationControllerWillAuthorizePayment(_ controller: PKPaymentAuthorizationController) {}
}
