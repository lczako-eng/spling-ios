//
// AppConfig.swift
// Spling
//
import Foundation

enum AppConfig {

    // MARK: - API
    enum API {
        static let baseURL = "https://api.spling.app/v1" // Replace with your backend
        static let menuEndpoint = "/menu"
        static let queueEndpoint = "/queue"
        static let ordersEndpoint = "/orders"
        static let ratingsEndpoint = "/ratings"
        static let paymentEndpoint = "/payment"
    }

    // MARK: - NFC
    enum NFC {
        static let alertMessage = "Hold your iPhone near the Spling terminal to start ordering."
        static let ndefStatusByteIndex = 0
        static let ndefLengthByteIndex = 1
    }

    // MARK: - Audio
    enum Audio {
        static let splingDingFile = "spling_ding"
        static let splingDingExtension = "mp3"
    }

    // MARK: - Loyalty
    enum Loyalty {
        static let pointsPerDollar = 10
        static let silverThreshold = 100
        static let goldThreshold = 500
        static let platinumThreshold = 1500
    }

    // MARK: - Accessibility
    enum Accessibility {
        static let minimumTextSize: Double = 14
        static let maximumTextSize: Double = 36
        static let defaultTextSize: Double = 17
    }

    // MARK: - Claude AI (Menu Scraper)
    enum Claude {
        /// Your Anthropic API key.
        /// Development: paste here. Production: load from Keychain or a backend proxy.
        /// Never commit a real key to source control.
        static let apiKey = "" // ← paste key here
        static let apiURL = "https://api.anthropic.com/v1/messages"
        static let apiVersion = "2023-06-01"
        /// claude-haiku-4-5: fast + cheap (~$0.001/scrape). Swap to claude-sonnet-4-6
        /// if you need higher accuracy on complex or poorly-structured menu pages.
        static let model = "claude-haiku-4-5-20251001"
        /// Token budget for extraction response. 2048 covers ~50 items comfortably.
        static let menuExtractionMaxTokens = 2048
        /// How long a scraped menu is valid before re-scraping. Default 24h.
        static let menuCacheTTL: TimeInterval = 60 * 60 * 24
    }
}
