//
// Models.swift
// Spling
//
import Foundation

// MARK: - NFC Terminal

enum TerminalType: String, Codable, Hashable, CaseIterable {
    case speakerBox  = "Drive-Through Speaker Box"
    case intercom    = "Drive-Through Intercom"
    case frontDesk   = "Front Desk"
    case kiosk       = "Self-Service Kiosk"

    var orderChannel: OrderChannel {
        switch self {
        case .speakerBox, .intercom: return .driveThrough
        case .frontDesk, .kiosk:     return .inStore
        }
    }

    var systemImage: String {
        switch self {
        case .speakerBox: return "speaker.wave.2.fill"
        case .intercom:   return "phone.fill"
        case .frontDesk:  return "person.crop.rectangle.fill"
        case .kiosk:      return "rectangle.portrait.fill"
        }
    }
}

struct NFCTagPayload: Codable {
    let vendorID:      String
    let terminalID:    String
    let terminalType:  TerminalType
    let schemaVersion: Int

    func toNDEFData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func from(ndefPayload: Data) throws -> NFCTagPayload {
        guard ndefPayload.count > 2 else { throw NFCTagDecodeError.tooShort }
        let langLen = Int(ndefPayload[1] & 0x3F)
        let start   = 2 + langLen
        guard start < ndefPayload.count else { throw NFCTagDecodeError.tooShort }
        let jsonData = ndefPayload.subdata(in: start..<ndefPayload.count)
        return try JSONDecoder().decode(NFCTagPayload.self, from: jsonData)
    }
}

enum NFCTagDecodeError: LocalizedError {
    case tooShort
    case invalidJSON(String)
    var errorDescription: String? {
        switch self {
        case .tooShort:            return "NFC tag data was too short to decode."
        case .invalidJSON(let m):  return "NFC tag JSON invalid: \(m)"
        }
    }
}

struct Terminal: Identifiable, Codable {
    let id:               String
    let vendorID:         String
    let type:             TerminalType
    let label:            String
    let queueLength:      Int
    let isAcceptingOrders: Bool
    let menuLastUpdated:  Date
    let posSystemID:      String
}

// MARK: - POS Integration

struct POSSystemInfo: Codable {
    let systemID:               String
    let provider:               String
    let endpointURL:            URL
    let requiresAcknowledgement: Bool
}

struct POSOrderPayload: Codable {
    let splingOrderID:          UUID
    let terminalID:             String
    let items:                  [POSOrderLine]
    let totalCents:             Int
    let paymentTransactionID:   String
    let channel:                OrderChannel
    let placedByCaretaker:      Bool
    let customerFacingReference: String
    let timestamp:              Date
}

struct POSOrderLine: Codable {
    let posItemID:          String
    let name:               String
    let quantity:           Int
    let unitPriceCents:     Int
    let modifiers:          [String]
    let specialInstructions: String
}

struct POSAcknowledgement: Codable {
    let splingOrderID:          UUID
    let posOrderID:             String
    let estimatedReadyMinutes:  Int
    let queuePosition:          Int
    let pickupReference:        String
    let acceptedAt:             Date
}

// MARK: - Vendor

struct Vendor: Identifiable, Codable, Hashable {
    let id:                         String
    let name:                       String
    let logoURL:                    URL?
    let address:                    String
    let menuCategories:             [MenuCategory]
    let terminals:                  [Terminal]
    let posInfo:                    POSSystemInfo?
    let supportsOrderHistory:       Bool
    let personalizedRecommendations: Bool

    init(
        id: String,
        name: String,
        logoURL: URL? = nil,
        address: String = "",
        menuCategories: [MenuCategory] = [],
        terminals: [Terminal] = [],
        posInfo: POSSystemInfo? = nil,
        supportsOrderHistory: Bool = true,
        personalizedRecommendations: Bool = false
    ) {
        self.id                          = id
        self.name                        = name
        self.logoURL                     = logoURL
        self.address                     = address
        self.menuCategories              = menuCategories
        self.terminals                   = terminals
        self.posInfo                     = posInfo
        self.supportsOrderHistory        = supportsOrderHistory
        self.personalizedRecommendations = personalizedRecommendations
    }
}

// MARK: - Menu

struct MenuCategory: Identifiable, Codable, Hashable {
    let id:    String
    let name:  String
    let items: [MenuItem]
}

struct MenuItem: Identifiable, Codable, Hashable {
    let id:             String
    let name:           String
    let description:    String
    let priceCents:     Int
    let imageURL:       URL?
    let customizations: [Customization]
    let allergens:      [String]
    let calories:       Int?

    var formattedPrice: String {
        String(format: "$%.2f", Double(priceCents) / 100.0)
    }
}

struct Customization: Identifiable, Codable, Hashable {
    let id:            String
    let name:          String
    let options:       [CustomizationOption]
    let isRequired:    Bool
    let maxSelections: Int
}

struct CustomizationOption: Identifiable, Codable, Hashable {
    let id:                  String
    let name:                String
    let additionalCostCents: Int
}

// MARK: - Order

struct OrderItem: Identifiable, Codable, Equatable {
    let id:                     UUID
    let menuItem:               MenuItem
    var quantity:               Int
    var selectedCustomizations: [String: String]  // customizationID → optionID
    var specialInstructions:    String

    /// Fixed: quantity is applied once to base price, extras are per-unit then multiplied.
    var subtotalCents: Int {
        let extras = selectedCustomizations.values.compactMap { optionID -> Int? in
            menuItem.customizations
                .flatMap(\.options)
                .first(where: { $0.id == optionID })
                .map(\.additionalCostCents)
        }.reduce(0, +)
        return (menuItem.priceCents + extras) * quantity
    }

    init(
        menuItem: MenuItem,
        quantity: Int = 1,
        customizations: [String: String] = [:],
        instructions: String = ""
    ) {
        self.id                     = UUID()
        self.menuItem               = menuItem
        self.quantity               = quantity
        self.selectedCustomizations = customizations
        self.specialInstructions    = instructions
    }
}

struct Order: Identifiable, Codable {
    let id:               UUID
    let vendorID:         String
    let vendorName:       String
    var items:            [OrderItem]
    let placedAt:         Date
    var status:           OrderStatus
    var paymentMethod:    PaymentMethod?
    var totalCents:       Int { items.reduce(0) { $0 + $1.subtotalCents } }
    var formattedTotal:   String { String(format: "$%.2f", Double(totalCents) / 100.0) }
    let channel:          OrderChannel
    let placedByCaretaker: Bool
    let terminalID:       String?
    let terminalType:     TerminalType?
    var posOrderID:       String?
    var pickupReference:  String?

    init(
        vendorID: String,
        vendorName: String,
        items: [OrderItem] = [],
        channel: OrderChannel = .inStore,
        placedByCaretaker: Bool = false,
        terminalID: String? = nil,
        terminalType: TerminalType? = nil
    ) {
        self.id                = UUID()
        self.vendorID          = vendorID
        self.vendorName        = vendorName
        self.items             = items
        self.placedAt          = Date()
        self.status            = .pending
        self.channel           = channel
        self.placedByCaretaker = placedByCaretaker
        self.terminalID        = terminalID
        self.terminalType      = terminalType
        self.posOrderID        = nil
        self.pickupReference   = nil
    }
}

enum OrderStatus: String, Codable, CaseIterable {
    case pending    = "Pending"
    case confirmed  = "Confirmed"
    case preparing  = "Preparing"
    case ready      = "Ready for Pickup"
    case completed  = "Completed"
    case cancelled  = "Cancelled"

    var systemImage: String {
        switch self {
        case .pending:   return "clock"
        case .confirmed: return "checkmark.circle"
        case .preparing: return "flame"
        case .ready:     return "bag.fill"
        case .completed: return "checkmark.seal.fill"
        case .cancelled: return "xmark.circle"
        }
    }
}

enum OrderChannel: String, Codable, CaseIterable, Identifiable {
    case driveThrough = "Drive-Through"
    case inStore      = "In-Store"
    case online       = "Online"

    var id: String { rawValue }

    var priority: Int {
        switch self {
        case .driveThrough: return 0
        case .inStore:      return 1
        case .online:       return 2
        }
    }

    var systemImage: String {
        switch self {
        case .driveThrough: return "car.fill"
        case .inStore:      return "building.2.fill"
        case .online:       return "globe"
        }
    }
}

// MARK: - Saved / Favourite Order

struct SavedOrder: Identifiable, Codable {
    let id:                      UUID
    var name:                    String
    let vendorID:                String
    let vendorName:              String
    let items:                   [OrderItem]
    let createdAt:               Date
    let createdByCaretaker:      Bool
    let originatingTerminalType: TerminalType?

    init(
        name: String,
        vendorID: String,
        vendorName: String,
        items: [OrderItem],
        createdByCaretaker: Bool = false,
        originatingTerminalType: TerminalType? = nil
    ) {
        self.id                      = UUID()
        self.name                    = name
        self.vendorID                = vendorID
        self.vendorName              = vendorName
        self.items                   = items
        self.createdAt               = Date()
        self.createdByCaretaker      = createdByCaretaker
        self.originatingTerminalType = originatingTerminalType
    }

    func asOrder(
        channel: OrderChannel? = nil,
        terminalID: String? = nil,
        terminalType: TerminalType? = nil
    ) -> Order {
        let resolvedChannel = channel ?? originatingTerminalType?.orderChannel ?? .inStore
        return Order(
            vendorID: vendorID,
            vendorName: vendorName,
            items: items,
            channel: resolvedChannel,
            placedByCaretaker: createdByCaretaker,
            terminalID: terminalID,
            terminalType: terminalType ?? originatingTerminalType
        )
    }
}

// MARK: - Queue

struct QueueStatus: Codable {
    let queueID:              String
    let position:             Int
    let estimatedWaitMinutes: Int
    let updatedAt:            Date
}

// MARK: - Payment

enum PaymentMethod: Codable, Hashable, Identifiable {
    case applePay
    case creditCard(last4: String, brand: String)
    case debitCard(last4: String, brand: String)
    case splingWallet(balance: Int)

    var id: String {
        switch self {
        case .applePay:              return "applePay"
        case .creditCard(let l, _): return "credit_\(l)"
        case .debitCard(let l, _):  return "debit_\(l)"
        case .splingWallet:         return "splingWallet"
        }
    }

    var displayName: String {
        switch self {
        case .applePay:                    return "Apple Pay"
        case .creditCard(let l, let b):    return "\(b) •••• \(l)"
        case .debitCard(let l, let b):     return "\(b) Debit •••• \(l)"
        case .splingWallet(let balance):
            return "Spling Wallet (\(String(format: "$%.2f", Double(balance) / 100.0)))"
        }
    }

    var systemImage: String {
        switch self {
        case .applePay:       return "applelogo"
        case .creditCard:     return "creditcard.fill"
        case .debitCard:      return "creditcard"
        case .splingWallet:   return "wallet.pass.fill"
        }
    }
}

struct PaymentResult: Codable {
    let transactionID: String
    let amountCents:   Int
    let method:        String
    let timestamp:     Date
    let receiptURL:    URL?
}

// MARK: - Loyalty

struct LoyaltyAccount: Codable {
    var points:         Int
    var lifetimePoints: Int
    var transactions:   [LoyaltyTransaction]

    var tier: LoyaltyTier {
        switch points {
        case AppConfig.Loyalty.platinumThreshold...: return .platinum
        case AppConfig.Loyalty.goldThreshold...:     return .gold
        case AppConfig.Loyalty.silverThreshold...:   return .silver
        default:                                     return .bronze
        }
    }

    var pointsToNextTier: Int? {
        switch tier {
        case .bronze:   return AppConfig.Loyalty.silverThreshold - points
        case .silver:   return AppConfig.Loyalty.goldThreshold - points
        case .gold:     return AppConfig.Loyalty.platinumThreshold - points
        case .platinum: return nil
        }
    }

    init() {
        self.points         = 0
        self.lifetimePoints = 0
        self.transactions   = []
    }
}

enum LoyaltyTier: String, Codable {
    case bronze   = "Bronze"
    case silver   = "Silver"
    case gold     = "Gold"
    case platinum = "Platinum"

    var color: String {
        switch self {
        case .bronze:   return "brown"
        case .silver:   return "gray"
        case .gold:     return "yellow"
        case .platinum: return "purple"
        }
    }

    var minimumPoints: Int {
        switch self {
        case .bronze:   return 0
        case .silver:   return AppConfig.Loyalty.silverThreshold
        case .gold:     return AppConfig.Loyalty.goldThreshold
        case .platinum: return AppConfig.Loyalty.platinumThreshold
        }
    }
}

struct LoyaltyTransaction: Identifiable, Codable {
    let id:           UUID
    let orderID:      UUID
    let pointsEarned: Int
    let date:         Date
    let vendorName:   String
}

// MARK: - Accessibility Settings

struct AccessibilitySettings: Codable {
    var voiceGuidanceEnabled:  Bool   = false
    var hapticFeedbackEnabled: Bool   = true
    var fontSize:              Double = AppConfig.Accessibility.defaultTextSize
    var highContrastEnabled:   Bool   = false
    var reducedMotionEnabled:  Bool   = false
    var caretakerModeEnabled:  Bool   = false
    var caretakerName:         String = ""
}

// MARK: - Review

/// A post-order review left by a Spling user about a vendor.
struct Review: Identifiable, Codable {
    let id:              UUID
    let vendorID:        String
    let vendorName:      String
    let orderID:         UUID
    let rating:          Int          // 1–5
    let title:           String
    let body:            String
    let authorName:      String       // Display name or "Anonymous"
    let createdAt:       Date
    var helpfulCount:    Int
    var isVerifiedOrder: Bool         // true when the review is tied to a real order

    init(
        vendorID: String,
        vendorName: String,
        orderID: UUID,
        rating: Int,
        title: String,
        body: String,
        authorName: String,
        isVerifiedOrder: Bool = true
    ) {
        self.id              = UUID()
        self.vendorID        = vendorID
        self.vendorName      = vendorName
        self.orderID         = orderID
        self.rating          = max(1, min(5, rating))
        self.title           = title
        self.body            = body
        self.authorName      = authorName
        self.createdAt       = Date()
        self.helpfulCount    = 0
        self.isVerifiedOrder = isVerifiedOrder
    }
}

/// Aggregated vendor review stats shown on the vendor header.
struct VendorReviewSummary: Codable {
    let vendorID:       String
    let averageRating:  Double
    let totalReviews:   Int
    let distribution:   [Int: Int]   // rating → count

    var formattedAverage: String {
        String(format: "%.1f", averageRating)
    }

    var starDisplay: String {
        let filled  = Int(averageRating.rounded())
        let stars   = String(repeating: "★", count: filled)
        let empty   = String(repeating: "☆", count: 5 - filled)
        return stars + empty
    }
}

// MARK: - User Profile

struct UserProfile: Codable {
    let id:                  UUID
    var displayName:         String
    var paymentMethods:      [PaymentMethod]
    var preferredPaymentID:  String?
    var savedOrders:         [SavedOrder]
    var loyaltyAccount:      LoyaltyAccount
    var accessibilitySettings: AccessibilitySettings
    var orderHistory:        [Order]
    var reviews:             [Review]
    var isCaretaker:         Bool

    init(displayName: String = "") {
        self.id                    = UUID()
        self.displayName           = displayName
        self.paymentMethods        = []
        self.preferredPaymentID    = nil
        self.savedOrders           = []
        self.loyaltyAccount        = LoyaltyAccount()
        self.accessibilitySettings = AccessibilitySettings()
        self.orderHistory          = []
        self.reviews               = []
        self.isCaretaker           = false
    }
}

// MARK: - Receipt

struct Receipt: Identifiable, Codable {
    let id:           UUID
    let order:        Order
    let payment:      PaymentResult
    let vendorName:   String
    let issuedAt:     Date
    var pointsEarned: Int

    init(order: Order, payment: PaymentResult, pointsEarned: Int = 0) {
        self.id           = UUID()
        self.order        = order
        self.payment      = payment
        self.vendorName   = order.vendorName
        self.issuedAt     = Date()
        self.pointsEarned = pointsEarned
    }
}
