//
// ReviewService.swift
// Spling
//
// Handles posting new reviews, fetching vendor reviews,
// and marking reviews as helpful — all against the Spling backend.
//
import Foundation

enum ReviewError: LocalizedError {
    case invalidInput(String)
    case alreadyReviewed
    case networkError(String)
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidInput(let msg): return msg
        case .alreadyReviewed:       return "You've already reviewed this order."
        case .networkError(let m):   return "Network error: \(m)"
        case .notFound:              return "Review not found."
        }
    }
}

actor ReviewService {
    static let shared = ReviewService()
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

    // MARK: - Submit Review

    /// Posts a new review for a vendor after an order is completed.
    /// The review is tied to the order ID, so each order can only be reviewed once.
    func submit(_ review: Review) async throws -> Review {
        // Validate locally before sending
        guard !review.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReviewError.invalidInput("Please add a title to your review.")
        }
        guard !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReviewError.invalidInput("Please add some details to your review.")
        }
        guard review.body.count <= AppConfig.Reviews.maxBodyLength else {
            throw ReviewError.invalidInput("Review is too long (max \(AppConfig.Reviews.maxBodyLength) characters).")
        }
        guard (AppConfig.Reviews.minRating...AppConfig.Reviews.maxRating).contains(review.rating) else {
            throw ReviewError.invalidInput("Rating must be between 1 and 5.")
        }

        guard let url = URL(string: "\(AppConfig.API.baseURL)\(AppConfig.API.reviewsEndpoint)") else {
            throw ReviewError.networkError("Invalid reviews endpoint URL.")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(review)
        req.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ReviewError.networkError("No HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return try decoder.decode(Review.self, from: data)
        case 409:
            throw ReviewError.alreadyReviewed
        default:
            throw ReviewError.networkError("HTTP \(http.statusCode)")
        }
    }

    // MARK: - Fetch Reviews for a Vendor

    /// Fetches paginated reviews for a given vendor, newest first.
    func fetchReviews(vendorID: String, page: Int = 0) async throws -> [Review] {
        guard let url = URL(
            string: "\(AppConfig.API.baseURL)\(AppConfig.API.reviewsEndpoint)/vendor/\(vendorID)?page=\(page)&limit=\(AppConfig.Reviews.pageSize)"
        ) else {
            throw ReviewError.networkError("Invalid URL")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode([Review].self, from: data)
    }

    // MARK: - Fetch Summary

    /// Returns aggregated star ratings and average for the given vendor.
    func fetchSummary(vendorID: String) async throws -> VendorReviewSummary {
        guard let url = URL(
            string: "\(AppConfig.API.baseURL)\(AppConfig.API.reviewsEndpoint)/vendor/\(vendorID)/summary"
        ) else {
            throw ReviewError.networkError("Invalid URL")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try decoder.decode(VendorReviewSummary.self, from: data)
    }

    // MARK: - Mark Helpful

    func markHelpful(reviewID: UUID) async throws {
        guard let url = URL(
            string: "\(AppConfig.API.baseURL)\(AppConfig.API.reviewsEndpoint)/\(reviewID.uuidString)/helpful"
        ) else {
            throw ReviewError.networkError("Invalid URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ReviewError.networkError("Could not mark review as helpful.")
        }
    }
}
