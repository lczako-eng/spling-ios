// ============================================================
// SPLING — FULL STACK v5
// Models_Additions.swift
// NEW models added in this sprint:
// • QR payload + parser
// • VoiceMLProfile (Adaptive ML Speech pathway)
// • PictureMenuPreference (Visual Picture Menu pathway)
// • CaregiverSession (Caregiver Pre-Programming pathway)
// • AccessibilityOrderingMode
// ADD these structs/enums to the bottom of your Models.swift
// ============================================================
import Foundation
import AVFoundation

// ─────────────────────────────────────────────────────────────
// MARK: - QR Payload Models (SPLA-002)
// ─────────────────────────────────────────────────────────────

/// Decoded from a Spling QR code at a drive-through or vendor location.
struct QRVendorPayload: Codable {
    let schemaVersion: String        // required — "1.0"
    let vendorWebsiteURL: String     // required — used for AI menu scrape
    let vendorID: String?            // optional — matches NFC vendorID if present
    let vendorName: String?          // optional — shown while AI loads
    let currency: String?            // optional — "CAD", "USD", etc.
    let defaultTerminalType: String? // optional — "drive-through", "kiosk", etc.
}

/// Bridge DTO passed from QR parser → VendorContextCoordinator
struct VendorContextInput {
    let vendorID: String?
    let vendorName: String?
    let vendorURL: URL    // non-nil — validated by parser
    let terminalType: TerminalType?
    let currency: String?
}

/// Parse errors thrown by QRPayloadParser
enum QRParseError: LocalizedError {
    case emptyPayload
    case invalidURL(String)
    case unsupportedSchemaVersion(String)

    var errorDescription: String? {
        switch self {
        case .emptyPayload:
            return "QR code contained no data."
        case .invalidURL(let raw):
            return "'\(raw)' is not a valid URL."
        case .unsupportedSchemaVersion(let v):
            return "QR schema version '\(v)' is not supported. Please update Spling."
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Adaptive ML Speech Pathway Models
// ─────────────────────────────────────────────────────────────

/// Persisted per-user voice model profile.
/// Stores phrase→menu-item mappings the ML model learns over time.
struct VoiceMLProfile: Codable {
    var userID: UUID
    /// Maps user phrases (lowercased) → MenuItem IDs
    var phraseMappings: [String: String]
    /// Phrases entered by a caregiver to pre-train the model
    var caregiverTrainedPhrases: [String: String]
    /// Total number of confirmed orders (used to gauge model maturity)
    var confirmedOrderCount: Int
    /// Last time the model was updated
    var lastUpdated: Date

    init(userID: UUID = UUID()) {
        self.userID = userID
        self.phraseMappings = [:]
        self.caregiverTrainedPhrases = [:]
        self.confirmedOrderCount = 0
        self.lastUpdated = Date()
    }

    /// Merges a confirmed speech→item pairing into the model.
    mutating func learn(phrase: String, menuItemID: String) {
        let key = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        phraseMappings[key] = menuItemID
        confirmedOrderCount += 1
        lastUpdated = Date()
    }

    /// Best-effort match: returns menuItemID for a raw speech string.
    func bestMatch(for rawSpeech: String) -> String? {
        let input = rawSpeech.lowercased()
        // Exact match first
        if let exact = phraseMappings[input] { return exact }
        if let exact = caregiverTrainedPhrases[input] { return exact }
        // Substring match
        let allMappings = phraseMappings.merging(caregiverTrainedPhrases) { $1 }
        return allMappings.first { input.contains($0.key) || $0.key.contains(input) }?.value
    }
}

/// Represents a single spoken recognition attempt
struct SpeechRecognitionAttempt: Identifiable {
    let id = UUID()
    let rawTranscript: String
    let confidence: Float  // 0.0 – 1.0
    let matchedMenuItemID: String?
    let timestamp: Date
}

// ─────────────────────────────────────────────────────────────
// MARK: - Visual Picture Menu Pathway Models
// ─────────────────────────────────────────────────────────────

enum PictureMenuTileSize: String, Codable, CaseIterable {
    case medium = "Medium"
    case large  = "Large"
    case xl     = "XL"

    var columns: Int {
        switch self { case .medium: return 3; case .large: return 2; case .xl: return 1 }
    }
    var minHeight: CGFloat {
        switch self { case .medium: return 120; case .large: return 160; case .xl: return 220 }
    }
}

/// User-specific picture menu preferences, persisted in UserProfile.
struct PictureMenuPreference: Codable {
    var tileSize: PictureMenuTileSize = .large
    var highContrastLabels: Bool = true
    var showCalories: Bool = true
    var showAllergens: Bool = true
    var preferredInteractionMode: PictureMenuInteractionMode = .tap

    enum PictureMenuInteractionMode: String, Codable, CaseIterable {
        case tap   = "Tap"
        case voice = "Voice"
        case swipe = "Swipe"
    }
}

/// Photo-cart entry — mirrors OrderItem but carries confirmed image URL
struct PictureCartEntry: Identifiable, Equatable {
    let id = UUID()
    let menuItem: MenuItem
    var quantity: Int
    var confirmedByPhoto: Bool  // true once user tapped photo to confirm
    var subtotalCents: Int { menuItem.priceCents * quantity }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Caregiver Pre-Programming Pathway Models
// ─────────────────────────────────────────────────────────────

/// A caregiver-programmed order that will be fulfilled by the user independently.
struct CaregiverProgrammedOrder: Identifiable, Codable {
    let id: UUID
    let caregiverName: String
    let userDisplayName: String
    let vendorID: String
    let vendorName: String
    let vendorURL: String?    // used to pre-load AI menu
    var items: [OrderItem]
    var dietaryRestrictions: [String]  // e.g. ["no nuts", "soft foods only"]
    var portionNotes: String
    var scheduleType: ScheduleType
    var scheduledDate: Date?
    var recurringPattern: String?  // e.g. "every Tuesday lunch"
    var createdAt: Date
    var isReadyForPickup: Bool
    var alertSent: Bool

    enum ScheduleType: String, Codable {
        case onDemand  = "On Demand"
        case scheduled = "Scheduled"
        case recurring = "Recurring"
    }

    init(
        caregiverName: String,
        userDisplayName: String,
        vendorID: String,
        vendorName: String,
        vendorURL: String? = nil,
        items: [OrderItem] = [],
        dietaryRestrictions: [String] = [],
        portionNotes: String = "",
        scheduleType: ScheduleType = .onDemand,
        scheduledDate: Date? = nil,
        recurringPattern: String? = nil
    ) {
        self.id = UUID()
        self.caregiverName = caregiverName
        self.userDisplayName = userDisplayName
        self.vendorID = vendorID
        self.vendorName = vendorName
        self.vendorURL = vendorURL
        self.items = items
        self.dietaryRestrictions = dietaryRestrictions
        self.portionNotes = portionNotes
        self.scheduleType = scheduleType
        self.scheduledDate = scheduledDate
        self.recurringPattern = recurringPattern
        self.createdAt = Date()
        self.isReadyForPickup = false
        self.alertSent = false
    }

    var totalCents: Int { items.reduce(0) { $0 + $1.subtotalCents } }
    var pickupAlertBody: String { "Your \(vendorName) order is ready to pick up." }
}

/// ML voice phrase entry a caregiver adds on behalf of a user
struct CaregiverVoicePhrase: Identifiable, Codable {
    let id: UUID
    let phrase: String       // what the user typically says
    let menuItemID: String   // what it maps to
    let menuItemName: String // for display
    let addedBy: String      // caregiver name

    init(phrase: String, menuItemID: String, menuItemName: String, addedBy: String) {
        self.id = UUID()
        self.phrase = phrase
        self.menuItemID = menuItemID
        self.menuItemName = menuItemName
        self.addedBy = addedBy
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Accessibility Ordering Mode
// ─────────────────────────────────────────────────────────────

/// Which of Spling's three ordering pathways the user is actively using.
enum AccessibilityOrderingMode: String, Codable, CaseIterable {
    case adaptiveSpeech = "Adaptive Speech"
    case pictureMenu    = "Picture Menu"
    case caregiverSetup = "Caregiver Setup"
    case standard       = "Standard"

    var systemImage: String {
        switch self {
        case .adaptiveSpeech: return "waveform.and.mic"
        case .pictureMenu:    return "photo.on.rectangle.angled"
        case .caregiverSetup: return "person.2.fill"
        case .standard:       return "hand.tap.fill"
        }
    }

    var description: String {
        switch self {
        case .adaptiveSpeech: return "Speak naturally — AI learns your voice"
        case .pictureMenu:    return "Tap large food photos to order"
        case .caregiverSetup: return "Set up an order for someone to pick up"
        case .standard:       return "Standard ordering"
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - UserProfile Extension
// ADD these three stored properties to the UserProfile struct in Models.swift:
//   var voiceMLProfile: VoiceMLProfile? = nil
//   var pictureMenuPreference: PictureMenuPreference? = nil
//   var caregiverProgrammedOrders: [CaregiverProgrammedOrder] = []
// ─────────────────────────────────────────────────────────────

extension UserProfile {
    /// Returns true if any programmed caregiver order is ready to pick up
    var hasPendingCaregiverPickup: Bool {
        caregiverProgrammedOrders.contains { $0.isReadyForPickup && !$0.alertSent }
    }
}
