// ============================================================
// SPLING — FULL STACK v5
// AppConfig_Additions.swift
//
// ADD the AppConfig enums below to your existing AppConfig.swift
// (or leave this as a separate file — both work in Swift)
// ============================================================
import Foundation

// ─────────────────────────────────────────────────────────────
// MARK: - AppConfig Additions
// ─────────────────────────────────────────────────────────────

extension AppConfig {

    // MARK: - QR Scanner
    enum QR {
        static let supportedSchemaVersions: [String] = ["1.0"]
        static let cameraPlistKey   = "NSCameraUsageDescription"
        static let cameraPlistValue = "Spling uses the camera to scan vendor QR codes."
    }

    // MARK: - Adaptive ML Speech
    enum Speech {
        static let micPlistKey   = "NSMicrophoneUsageDescription"
        static let micPlistValue = "Spling uses the microphone to understand your spoken order."

        static let speechRecognitionPlistKey   = "NSSpeechRecognitionUsageDescription"
        static let speechRecognitionPlistValue = "Spling uses speech recognition to interpret your order — even with slurred or slow speech."

        /// Minimum transcript character count before attempting ML match
        static let minimumTranscriptLength: Int = 2

        /// Confidence threshold below which we show "Did you mean?" confirmation
        static let confirmationThreshold: Float = 0.85
    }

    // MARK: - Picture Menu
    enum PictureMenu {
        static let defaultTileSize: PictureMenuTileSize = .large
        static let hapticOnEveryTap: Bool = true
        static let photoCartMaxItems: Int = 20
    }

    // MARK: - Caregiver
    enum Caregiver {
        static let maxProgrammedOrders: Int = 10
        static let pickupNotificationCategoryID = "CAREGIVER_PICKUP"
        static let pickupNotificationTitle      = "Your order is ready to pick up!"
    }
}
