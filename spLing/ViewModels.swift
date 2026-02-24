//
// ViewModels.swift
// Spling
//
import Foundation
import Combine

// MARK: - User Session ViewModel

@MainActor
class UserSessionViewModel: ObservableObject {
    @Published var profile:    UserProfile = PersistenceManager.shared.loadProfile()
    @Published var authState:  AuthState   = .unauthenticated
    @Published var authError:  String?

    enum AuthState { case unauthenticated, authenticating, authenticated }

    // MARK: Auth

    func authenticate() {
        guard authState != .authenticating else { return }
        authState = .authenticating
        authError = nil
        Task {
            do {
                try await AuthManager.shared.authenticate()
                HapticManager.shared.notification(.success)
                authState = .authenticated
            } catch AuthError.cancelled {
                authState = .unauthenticated
            } catch {
                HapticManager.shared.notification(.error)
                authError = error.localizedDescription
                authState = .unauthenticated
            }
        }
    }

    func signOut() {
        authState = .unauthenticated
        profile   = UserProfile()
        PersistenceManager.shared.clearAll()
    }

    // MARK: Payment

    var preferredPaymentMethod: PaymentMethod? {
        guard let id = profile.preferredPaymentID else { return profile.paymentMethods.first }
        return profile.paymentMethods.first { $0.id == id }
    }

    // MARK: Loyalty

    func addPoints(for order: Order) {
        let earned = (order.totalCents / 100) * AppConfig.Loyalty.pointsPerDollar
        profile.loyaltyAccount.points          += earned
        profile.loyaltyAccount.lifetimePoints  += earned
        let tx = LoyaltyTransaction(
            id:           UUID(),
            orderID:      order.id,
            pointsEarned: earned,
            date:         Date(),
            vendorName:   order.vendorName
        )
        profile.loyaltyAccount.transactions.append(tx)
        save()
    }

    // MARK: Saved Orders

    func savedOrders(for vendorID: String) -> [SavedOrder] {
        profile.savedOrders.filter { $0.vendorID == vendorID }
    }

    func saveOrder(_ savedOrder: SavedOrder) {
        profile.savedOrders.append(savedOrder)
        save()
    }

    func deleteSavedOrder(id: UUID) {
        profile.savedOrders.removeAll { $0.id == id }
        save()
    }

    // MARK: Order History

    func addToHistory(_ order: Order) {
        profile.orderHistory.insert(order, at: 0)
        save()
    }

    // MARK: Reviews

    func addReview(_ review: Review) {
        profile.reviews.append(review)
        save()
    }

    func hasReviewed(orderID: UUID) -> Bool {
        profile.reviews.contains { $0.orderID == orderID }
    }

    // MARK: Persistence

    private func save() {
        PersistenceManager.shared.saveProfile(profile)
    }
}

// MARK: - Vendor ViewModel

@MainActor
class VendorViewModel: ObservableObject {
    @Published var vendor:               Vendor?
    @Published var detectedTerminal:     Terminal?
    @Published var orderHistoryAtVendor: [SavedOrder]  = []
    @Published var personalizedOffers:   [String]      = []
    @Published var loadState:            LoadState     = .idle

    enum LoadState { case idle, loading, loaded, failed(String) }

    func load(from tagPayload: NFCTagPayload, userProfile: UserProfile) async {
        loadState = .loading
        guard
            let vendorURL   = URL(string: "\(AppConfig.API.baseURL)/vendor/\(tagPayload.vendorID)"),
            let terminalURL = URL(string: "\(AppConfig.API.baseURL)/terminal/\(tagPayload.terminalID)")
        else {
            loadState = .failed("Invalid vendor or terminal URL.")
            return
        }
        do {
            async let vendorFetch   = URLSession.shared.data(from: vendorURL)
            async let terminalFetch = URLSession.shared.data(from: terminalURL)
            let (vendorData,   vendorResp)   = try await vendorFetch
            let (terminalData, terminalResp) = try await terminalFetch

            guard
                let vh = vendorResp   as? HTTPURLResponse, (200...299).contains(vh.statusCode),
                let th = terminalResp as? HTTPURLResponse, (200...299).contains(th.statusCode)
            else {
                loadState = .failed("Failed to load vendor or terminal data.")
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            vendor          = try decoder.decode(Vendor.self,   from: vendorData)
            detectedTerminal = try decoder.decode(Terminal.self, from: terminalData)

            if vendor?.supportsOrderHistory == true {
                orderHistoryAtVendor = userProfile.savedOrders.filter { $0.vendorID == tagPayload.vendorID }
            }
            if vendor?.personalizedRecommendations == true {
                await loadPersonalisedOffers(
                    vendorID:    tagPayload.vendorID,
                    loyaltyTier: userProfile.loyaltyAccount.tier.rawValue
                )
            }
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func loadPersonalisedOffers(vendorID: String, loyaltyTier: String) async {
        guard let url = URL(string: "\(AppConfig.API.baseURL)/vendor/\(vendorID)/offers?tier=\(loyaltyTier)") else { return }
        do {
            let (data, _)    = try await URLSession.shared.data(from: url)
            personalizedOffers = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } catch {
            personalizedOffers = []
        }
    }

    func loadFromAIResult(vendor: Vendor) {
        self.vendor              = vendor
        detectedTerminal         = nil
        orderHistoryAtVendor     = []
        personalizedOffers       = []
        loadState                = .loaded
    }

    // MARK: - Mock (simulator / preview)

    func loadMockVendor(from tagPayload: NFCTagPayload) {
        let mockTerminal = Terminal(
            id:               tagPayload.terminalID,
            vendorID:         tagPayload.vendorID,
            type:             tagPayload.terminalType,
            label:            tagPayload.terminalType == .speakerBox ? "Lane 1 Speaker" : "Drive-Through Intercom",
            queueLength:      2,
            isAcceptingOrders: true,
            menuLastUpdated:  Date(),
            posSystemID:      "pos_001"
        )
        vendor = Vendor(
            id:      tagPayload.vendorID,
            name:    "Tim Hortons",
            address: "123 Main St",
            menuCategories: [
                MenuCategory(id: "cat1", name: "Drinks", items: [
                    MenuItem(id: "m1", name: "Medium Coffee",        description: "Freshly brewed",        priceCents: 219, imageURL: nil, customizations: [], allergens: [], calories: 10),
                    MenuItem(id: "m2", name: "Large Coffee",         description: "Freshly brewed",        priceCents: 259, imageURL: nil, customizations: [], allergens: [], calories: 15),
                    MenuItem(id: "m3", name: "Iced Capp",            description: "Blended frozen coffee", priceCents: 399, imageURL: nil, customizations: [], allergens: ["Dairy"], calories: 260)
                ]),
                MenuCategory(id: "cat2", name: "Food", items: [
                    MenuItem(id: "m4", name: "Everything Bagel",       description: "With cream cheese",                  priceCents: 299, imageURL: nil, customizations: [], allergens: ["Gluten","Dairy"], calories: 350),
                    MenuItem(id: "m5", name: "Farmers Breakfast Wrap", description: "Egg, cheese, sausage, hash brown",   priceCents: 519, imageURL: nil, customizations: [], allergens: ["Gluten","Dairy","Egg"], calories: 500)
                ])
            ],
            terminals: [mockTerminal],
            posInfo: POSSystemInfo(
                systemID:               "pos_001",
                provider:               "NCR Aloha",
                endpointURL:            URL(string: "\(AppConfig.API.baseURL)/pos/orders")!,
                requiresAcknowledgement: true
            ),
            supportsOrderHistory:        true,
            personalizedRecommendations: false
        )
        detectedTerminal = mockTerminal
        loadState = .loaded
    }
}

// MARK: - Cart ViewModel

@MainActor
class CartViewModel: ObservableObject {
    @Published var items:                 [OrderItem]      = []
    @Published var selectedPaymentMethod: PaymentMethod?
    @Published var specialInstructions:   String           = ""

    var vendorID:            String        = ""
    var vendorName:          String        = ""
    var activeTerminalID:    String?       = nil
    var activeTerminalType:  TerminalType? = nil

    var totalCents:    Int    { items.reduce(0) { $0 + $1.subtotalCents } }
    var formattedTotal: String { String(format: "$%.2f", Double(totalCents) / 100.0) }
    var isEmpty:       Bool   { items.isEmpty }
    var itemCount:     Int    { items.reduce(0) { $0 + $1.quantity } }

    func add(_ item: MenuItem, customizations: [String: String] = []) {
        if let idx = items.firstIndex(where: { $0.menuItem.id == item.id }) {
            items[idx].quantity += 1
        } else {
            items.append(OrderItem(menuItem: item, customizations: customizations))
        }
        HapticManager.shared.impact(.light)
    }

    func remove(_ item: OrderItem) {
        items.removeAll { $0.id == item.id }
    }

    func updateQuantity(of item: OrderItem, to quantity: Int) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if quantity <= 0 { items.remove(at: idx) }
        else             { items[idx].quantity = quantity }
    }

    func clear() {
        items                = []
        selectedPaymentMethod = nil
        specialInstructions  = ""
        activeTerminalID     = nil
        activeTerminalType   = nil
    }

    func loadFromSavedOrder(_ saved: SavedOrder) {
        vendorID           = saved.vendorID
        vendorName         = saved.vendorName
        items              = saved.items
        activeTerminalType = saved.originatingTerminalType
    }

    func asOrder(channel: OrderChannel? = nil, placedByCaretaker: Bool = false) -> Order {
        let resolvedChannel = channel ?? activeTerminalType?.orderChannel ?? .inStore
        return Order(
            vendorID:         vendorID,
            vendorName:       vendorName,
            items:            items,
            channel:          resolvedChannel,
            placedByCaretaker: placedByCaretaker,
            terminalID:       activeTerminalID,
            terminalType:     activeTerminalType
        )
    }
}

// MARK: - Order ViewModel

@MainActor
class OrderViewModel: ObservableObject {
    @Published var activeOrder:       Order?
    @Published var queueStatus:       QueueStatus?
    @Published var posAcknowledgement: POSAcknowledgement?
    @Published var receipt:           Receipt?
    @Published var orderState:        OrderState   = .idle
    @Published var errorMessage:      String?

    enum OrderState: Equatable {
        case idle, submitting, processingPayment, routingToPOS, inQueue, completed
        case failed(String)

        static func == (lhs: OrderState, rhs: OrderState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.submitting, .submitting),
                 (.processingPayment, .processingPayment),
                 (.routingToPOS, .routingToPOS),
                 (.inQueue, .inQueue), (.completed, .completed): return true
            case (.failed(let a), .failed(let b)):               return a == b
            default:                                             return false
            }
        }
    }

    func submit(order: Order, paymentMethod: PaymentMethod, posInfo: POSSystemInfo?) async {
        orderState  = .submitting
        errorMessage = nil

        do {
            // Step 1: POST to Spling backend
            guard let url = URL(string: "\(AppConfig.API.baseURL)\(AppConfig.API.ordersEndpoint)") else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(order)
            let (_, orderResponse) = try await URLSession.shared.data(for: request)
            guard let orderHTTP = orderResponse as? HTTPURLResponse,
                  (200...299).contains(orderHTTP.statusCode)
            else { throw URLError(.badServerResponse) }

            activeOrder = order

            // Step 2: Process payment
            orderState = .processingPayment
            let paymentResult = try await PaymentManager.shared.process(order: order, method: paymentMethod)

            // Step 3: Route to POS
            if let posInfo {
                orderState = .routingToPOS
                let ack = try await POSService.shared.submit(
                    order:                order,
                    paymentTransactionID: paymentResult.transactionID,
                    posInfo:             posInfo
                )
                posAcknowledgement      = ack
                activeOrder?.posOrderID = ack.posOrderID
                activeOrder?.pickupReference = ack.pickupReference
            }

            // Step 4: Build receipt
            receipt = Receipt(order: activeOrder ?? order, payment: paymentResult)
            HapticManager.shared.notification(.success)
            AudioManager.shared.playSplingDing()
            orderState = .completed

        } catch let payErr as PaymentError {
            HapticManager.shared.notification(.error)
            orderState   = .failed(payErr.localizedDescription)
            errorMessage = payErr.localizedDescription
        } catch {
            HapticManager.shared.notification(.error)
            orderState   = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func pollQueueStatus(for orderID: UUID) async {
        do {
            queueStatus = try await POSService.shared.fetchQueueStatus(queueID: orderID.uuidString)
            if case .completed = orderState { return }
            orderState = .inQueue
        } catch {
            errorMessage = "Could not fetch queue position: \(error.localizedDescription)"
        }
    }

    func reset() {
        activeOrder        = nil
        queueStatus        = nil
        posAcknowledgement = nil
        receipt            = nil
        orderState         = .idle
        errorMessage       = nil
    }
}

// MARK: - Order Prioritization ViewModel

@MainActor
class OrderPrioritizationViewModel: ObservableObject {
    @Published private(set) var orders: [Order] = []

    var prioritizedOrders: [Order] {
        orders.sorted {
            if $0.channel.priority != $1.channel.priority { return $0.channel.priority < $1.channel.priority }
            if $0.placedByCaretaker != $1.placedByCaretaker { return $0.placedByCaretaker }
            return $0.placedAt < $1.placedAt
        }
    }

    func add(_ order: Order)         { orders.append(order) }
    func complete(orderID: UUID)      { orders.removeAll { $0.id == orderID } }

    func addSampleOrders() {
        let samples: [(OrderChannel, Bool)] = [
            (.online, false), (.inStore, false),
            (.driveThrough, false), (.inStore, true)
        ]
        samples.forEach { channel, isCaretaker in
            orders.append(Order(vendorID: "v1", vendorName: "Tim Hortons",
                                channel: channel, placedByCaretaker: isCaretaker))
        }
    }
}

// MARK: - Accessibility Settings ViewModel

@MainActor
class AccessibilityViewModel: ObservableObject {
    @Published var settings: AccessibilitySettings

    init(settings: AccessibilitySettings = AccessibilitySettings()) {
        self.settings = settings
    }

    var dynamicFontSize: CGFloat { CGFloat(settings.fontSize) }

    func resetToDefaults() { settings = AccessibilitySettings() }

    func announceForVoiceOver(_ message: String) {
        guard settings.voiceGuidanceEnabled else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

// MARK: - Rating ViewModel

@MainActor
class RatingViewModel: ObservableObject {
    @Published var rating:   Int         = 5
    @Published var feedback: String      = ""
    @Published var state:    SubmitState = .idle

    enum SubmitState { case idle, submitting, submitted, failed(String) }

    func submit(for orderID: UUID) async {
        guard state != .submitting else { return }
        state = .submitting
        guard let url = URL(string: "\(AppConfig.API.baseURL)\(AppConfig.API.ratingsEndpoint)") else {
            state = .failed("Invalid URL."); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "orderID": orderID.uuidString,
            "rating":  rating,
            "feedback": feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                state = .failed("Submission failed. Please try again."); return
            }
            HapticManager.shared.notification(.success)
            state = .submitted
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Review ViewModel

@MainActor
class ReviewViewModel: ObservableObject {
    @Published var rating:      Int          = 5
    @Published var title:       String       = ""
    @Published var body:        String       = ""
    @Published var isAnonymous: Bool         = false
    @Published var state:       ReviewState  = .idle
    @Published var vendorReviews: [Review]   = []
    @Published var reviewSummary: VendorReviewSummary?
    @Published var isLoadingReviews: Bool    = false

    enum ReviewState {
        case idle, submitting, submitted, failed(String)
    }

    var characterCount: Int    { body.count }
    var isOverLimit:    Bool   { body.count > AppConfig.Reviews.maxBodyLength }
    var canSubmit:      Bool   {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isOverLimit &&
        state != .submitting
    }

    // MARK: - Submit a new review

    func submitReview(
        order: Order,
        authorName: String,
        sessionVM: UserSessionViewModel
    ) async {
        guard canSubmit else { return }
        guard !sessionVM.hasReviewed(orderID: order.id) else {
            state = .failed("You've already reviewed this order.")
            return
        }

        state = .submitting
        let review = Review(
            vendorID:        order.vendorID,
            vendorName:      order.vendorName,
            orderID:         order.id,
            rating:          rating,
            title:           title.trimmingCharacters(in: .whitespacesAndNewlines),
            body:            body.trimmingCharacters(in: .whitespacesAndNewlines),
            authorName:      isAnonymous ? "Anonymous" : authorName,
            isVerifiedOrder: true
        )

        do {
            let submitted = try await ReviewService.shared.submit(review)
            sessionVM.addReview(submitted)
            HapticManager.shared.notification(.success)
            state = .submitted
        } catch {
            HapticManager.shared.notification(.error)
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Load vendor reviews

    func loadReviews(vendorID: String) async {
        isLoadingReviews = true
        defer { isLoadingReviews = false }
        do {
            async let reviewsFetch  = ReviewService.shared.fetchReviews(vendorID: vendorID)
            async let summaryFetch  = ReviewService.shared.fetchSummary(vendorID: vendorID)
            vendorReviews  = try await reviewsFetch
            reviewSummary  = try await summaryFetch
        } catch {
            // Non-critical — reviews are supplementary; don't block the menu
            #if DEBUG
            print("[ReviewViewModel] Load error: \(error)")
            #endif
        }
    }

    // MARK: - Mark helpful

    func markHelpful(review: Review) async {
        do {
            try await ReviewService.shared.markHelpful(reviewID: review.id)
            if let idx = vendorReviews.firstIndex(where: { $0.id == review.id }) {
                vendorReviews[idx].helpfulCount += 1
            }
        } catch {
            #if DEBUG
            print("[ReviewViewModel] markHelpful error: \(error)")
            #endif
        }
    }

    func reset() {
        rating      = 5
        title       = ""
        body        = ""
        isAnonymous = false
        state       = .idle
    }
}

// MARK: - AI Menu ViewModel

@MainActor
class AIMenuViewModel: ObservableObject {
    @Published var urlText:       String      = ""
    @Published var vendorNameText: String     = ""
    @Published var state:         ScrapeState = .idle
    @Published var result:        ScrapedMenuCache?
    @Published var errorMessage:  String?

    enum ScrapeState {
        case idle, fetching, parsing, done, failed(String)
    }

    var isLoading: Bool {
        switch state { case .fetching, .parsing: return true; default: return false }
    }

    var statusLabel: String {
        switch state {
        case .idle:           return "Paste a restaurant or store URL above"
        case .fetching:       return "Loading website…"
        case .parsing:        return "AI is reading the menu…"
        case .done:           return "Menu ready!"
        case .failed(let m):  return m
        }
    }

    func scrape() {
        guard !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isLoading else { return }
        state        = .fetching
        errorMessage = nil
        result       = nil
        Task {
            do {
                state = .fetching
                let name  = vendorNameText.trimmingCharacters(in: .whitespacesAndNewlines)
                let cache = try await AIMenuService.shared.fetchMenu(
                    from:       urlText,
                    vendorName: name.isEmpty ? nil : name
                )
                state  = .parsing
                try? await Task.sleep(nanoseconds: 600_000_000)
                result = cache
                state  = .done
                HapticManager.shared.notification(.success)
            } catch {
                let msg  = error.localizedDescription
                state    = .failed(msg)
                errorMessage = msg
                HapticManager.shared.notification(.error)
            }
        }
    }

    func refresh() {
        Task { await AIMenuService.shared.clearCache(for: urlText) }
        scrape()
    }

    func reset() {
        urlText       = ""
        vendorNameText = ""
        state         = .idle
        result        = nil
        errorMessage  = nil
    }
}
