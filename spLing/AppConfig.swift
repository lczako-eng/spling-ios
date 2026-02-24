//
// AppConfig.swift
// Spling
//
import Foundation

enum AppConfig {

    // MARK: - API
    enum API {
        static let baseURL = "https://api.spling.app/v1"
        static let menuEndpoint      = "/menu"
        static let queueEndpoint     = "/queue"
        static let ordersEndpoint    = "/orders"
        static let ratingsEndpoint   = "/ratings"
        static let paymentEndpoint   = "/payment"
        static let reviewsEndpoint   = "/reviews"
        static let vendorEndpoint    = "/vendor"
        static let terminalEndpoint  = "/terminal"
    }

    // MARK: - NFC
    enum NFC {
        static let alertMessage        = "Hold your iPhone near the Spling terminal to start your order."
        static let ndefStatusByteIndex = 0
        static let ndefLengthByteIndex = 1
    }

    // MARK: - Audio
    enum Audio {
        static let splingDingFile      = "spling_ding"
        static let splingDingExtension = "mp3"
    }

    // MARK: - Loyalty
    enum Loyalty {
        static let pointsPerDollar    = 10
        static let silverThreshold    = 100
        static let goldThreshold      = 500
        static let platinumThreshold  = 1500
    }

    // MARK: - Accessibility
    enum Accessibility {
        static let minimumTextSize: Double = 14
        static let maximumTextSize: Double = 36
        static let defaultTextSize: Double = 17
    }

    // MARK: - Claude AI (Menu Scraper)
    enum Claude {
        /// Load from Keychain in production — never commit a real key.
        static var apiKey: String {
            KeychainManager.shared.retrieve(key: "anthropic_api_key") ?? ""
        }
        static let apiURL     = "https://api.anthropic.com/v1/messages"
        static let apiVersion = "2023-06-01"
        /// claude-haiku-4-5: fast + cheap. Swap to claude-sonnet-4-6 for complex menus.
        static let model                    = "claude-haiku-4-5-20251001"
        static let menuExtractionMaxTokens  = 2048
        /// 24-hour cache TTL before re-scraping.
        static let menuCacheTTL: TimeInterval = 60 * 60 * 24
    }

    // MARK: - Reviews
    enum Reviews {
        static let maxRating       = 5
        static let minRating       = 1
        static let maxBodyLength   = 500
        static let pageSize        = 20
    }

    // MARK: - Payment
    enum Payment {
        static let stripePublishableKey = "" // Set before shipping
        static let currency             = "cad"
        static let countryCode          = "CA"
    }
}
