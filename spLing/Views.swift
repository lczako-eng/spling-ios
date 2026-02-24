//
// Views.swift
// Spling
//
import SwiftUI

// MARK: - App Root

@main
struct SplingApp: App {
    @StateObject private var session       = UserSessionViewModel()
    @StateObject private var accessibility = AccessibilityViewModel()
    @StateObject private var cart          = CartViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .environmentObject(accessibility)
                .environmentObject(cart)
                .preferredColorScheme(accessibility.settings.highContrastEnabled ? .dark : nil)
                .onAppear { HapticManager.shared.prepare() }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var session: UserSessionViewModel
    var body: some View {
        switch session.authState {
        case .authenticated:                       MainTabView()
        case .unauthenticated, .authenticating:    AuthView()
        }
    }
}

// MARK: - Auth View

struct AuthView: View {
    @EnvironmentObject var session:       UserSessionViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "fork.knife.circle.fill")
                    .resizable().scaledToFit().frame(width: 90, height: 90)
                    .foregroundStyle(.blue)
                Text("spLing")
                    .font(.system(size: accessibility.dynamicFontSize + 20, weight: .bold, design: .rounded))
                Text("Order smarter. No more waiting.")
                    .font(.system(size: accessibility.dynamicFontSize))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            if let error = session.authError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            Button {
                session.authenticate()
            } label: {
                Group {
                    if session.authState == .authenticating {
                        ProgressView().tint(.white)
                    } else {
                        Label("Sign in with \(AuthManager.shared.biometryName)", systemImage: "faceid")
                    }
                }
                .frame(maxWidth: .infinity)
                .font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(session.authState == .authenticating)
            .padding(.horizontal)
            .accessibilityLabel("Authenticate with \(AuthManager.shared.biometryName) to access Spling")
            Spacer().frame(height: 32)
        }
        .padding()
    }
}

// MARK: - Main Tab View

struct MainTabView: View {
    @EnvironmentObject var session: UserSessionViewModel
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Home",    systemImage: "house.fill") }
            NavigationStack { OrderHistoryView() }
                .tabItem { Label("Orders",  systemImage: "bag.fill") }
            NavigationStack { LoyaltyView() }
                .tabItem { Label("Rewards", systemImage: "trophy.fill") }
            NavigationStack { ProfileView() }
                .tabItem { Label("Profile", systemImage: "person.crop.circle.fill") }
        }
    }
}

// MARK: - Home View

struct HomeView: View {
    @EnvironmentObject var session:       UserSessionViewModel
    @EnvironmentObject var cart:          CartViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel

    @StateObject private var nfcManager = NFCManager()
    @StateObject private var vendorVM   = VendorViewModel()

    @State private var showVendorMenu          = false
    @State private var showSavedOrders         = false
    @State private var showOrderPrioritization = false
    @State private var showCaretakerSetup      = false
    @State private var showAIMenuEntry         = false
    @State private var nfcErrorMessage: String?
    @State private var showNFCError            = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                greetingHeader
                loyaltyCard
                quickActions
                if session.profile.accessibilitySettings.caretakerModeEnabled {
                    caretakerSection
                }
                savedOrdersSection
            }
            .padding()
        }
        .navigationTitle("spLing")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(destination: AccessibilitySettingsView()) {
                    Image(systemName: "accessibility")
                }
                .accessibilityLabel("Accessibility Settings")
            }
        }
        .navigationDestination(isPresented: $showVendorMenu) {
            if let vendor = vendorVM.vendor {
                VendorMenuView(vendor: vendor,
                               terminal: vendorVM.detectedTerminal,
                               orderHistory: vendorVM.orderHistoryAtVendor,
                               personalizedOffers: vendorVM.personalizedOffers)
            }
        }
        .navigationDestination(isPresented: $showSavedOrders)         { SavedOrdersView() }
        .navigationDestination(isPresented: $showOrderPrioritization) { OrderPrioritizationView() }
        .navigationDestination(isPresented: $showCaretakerSetup)      { CaretakerSetupView() }
        .sheet(isPresented: $showAIMenuEntry) {
            AIMenuView()
                .environmentObject(accessibility)
                .environmentObject(cart)
                .environmentObject(session)
        }
        .alert("NFC Error", isPresented: $showNFCError) {
            Button("OK") { nfcManager.reset() }
        } message: {
            Text(nfcErrorMessage ?? "An unknown NFC error occurred.")
        }
        .onChange(of: nfcManager.error) { _, error in
            if let error {
                nfcErrorMessage = error.localizedDescription
                showNFCError    = true
                accessibility.announceForVoiceOver("NFC error: \(error.localizedDescription)")
            }
        }
        .onChange(of: nfcManager.detectedPayload) { _, tagPayload in
            guard let tagPayload else { return }
            Task {
                vendorVM.loadMockVendor(from: tagPayload)   // swap for vendorVM.load() when backend is live
                if let vendor = vendorVM.vendor {
                    cart.vendorID          = vendor.id
                    cart.vendorName        = vendor.name
                    cart.activeTerminalID  = tagPayload.terminalID
                    cart.activeTerminalType = tagPayload.terminalType
                    vendorVM.orderHistoryAtVendor = session.savedOrders(for: vendor.id)
                    showVendorMenu         = true
                    accessibility.announceForVoiceOver(
                        "Detected \(tagPayload.terminalType.rawValue) at \(vendor.name). Menu loaded."
                    )
                }
            }
        }
    }

    private var greetingHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Good \(timeOfDay),")
                    .foregroundStyle(.secondary)
                    .font(.system(size: accessibility.dynamicFontSize - 2))
                Text(session.profile.displayName.isEmpty ? "Welcome back" : session.profile.displayName)
                    .font(.system(size: accessibility.dynamicFontSize + 4, weight: .bold))
            }
            Spacer()
        }
    }

    private var timeOfDay: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour { case 0..<12: return "morning"; case 12..<17: return "afternoon"; default: return "evening" }
    }

    private var loyaltyCard: some View {
        let tier = session.profile.loyaltyAccount.tier
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(session.profile.loyaltyAccount.points) pts")
                    .font(.system(size: accessibility.dynamicFontSize + 4, weight: .bold))
                Text(tier.rawValue + " Member")
                    .font(.system(size: accessibility.dynamicFontSize - 2)).foregroundStyle(.secondary)
                if let next = session.profile.loyaltyAccount.pointsToNextTier {
                    Text("\(next) pts to next tier")
                        .font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "trophy.fill").font(.system(size: 36)).foregroundStyle(tierColor(tier))
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loyalty: \(session.profile.loyaltyAccount.points) points, \(tier.rawValue) tier")
    }

    private func tierColor(_ tier: LoyaltyTier) -> Color {
        switch tier { case .bronze: return .brown; case .silver: return .gray; case .gold: return .yellow; case .platinum: return .purple }
    }

    private var quickActions: some View {
        VStack(spacing: 12) {
            Button {
                AudioManager.shared.playSplingDing()
                HapticManager.shared.impact(.medium)
                nfcManager.startSession()
                accessibility.announceForVoiceOver("Starting NFC scan. Hold your phone near the terminal.")
            } label: {
                HStack {
                    Image(systemName: nfcManager.isScanning ? "wave.3.right.circle.fill" : "wave.3.right.circle")
                        .font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nfcManager.isScanning ? "Scanning…" : "Tap to Order")
                            .font(.system(size: accessibility.dynamicFontSize + 2, weight: .semibold))
                        Text("Hold near NFC terminal")
                            .font(.system(size: accessibility.dynamicFontSize - 4)).opacity(0.8)
                    }
                    Spacer()
                }
                .padding().frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(nfcManager.isScanning)
            .accessibilityLabel("Tap to start NFC order")
            .accessibilityHint("Hold your iPhone near a Spling terminal")

            HStack(spacing: 12) {
                ActionButton(title: "Saved Orders", icon: "star.fill",    color: .orange) { showSavedOrders = true }
                ActionButton(title: "Order Queue",  icon: "list.number",  color: .purple) { showOrderPrioritization = true }
            }

            Button { showAIMenuEntry = true } label: {
                HStack {
                    Image(systemName: "brain.head.profile").font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add Vendor by Website")
                            .font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
                        Text("AI reads any restaurant menu automatically")
                            .font(.system(size: accessibility.dynamicFontSize - 4)).opacity(0.8)
                    }
                    Spacer()
                    Image(systemName: "sparkles").foregroundStyle(.yellow)
                }
                .padding().frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.blue)
            .accessibilityLabel("Add a vendor by entering their website URL. AI will extract the menu.")
        }
    }

    private var caretakerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Caretaker Mode", systemImage: "person.2.fill")
                .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                .foregroundStyle(.secondary)
            Button { showCaretakerSetup = true } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Set Up Order for User").font(.system(size: accessibility.dynamicFontSize))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).tint(.green)
            .accessibilityLabel("Set up an order for the person you care for")
        }
        .padding()
        .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var savedOrdersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.profile.savedOrders.isEmpty {
                Text("Quick Reorder")
                    .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(session.profile.savedOrders.prefix(3)) { saved in
                    SavedOrderRowView(saved: saved) {
                        cart.loadFromSavedOrder(saved)
                        showVendorMenu = true
                    }
                }
            }
        }
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let title:  String
    let icon:   String
    let color:  Color
    let action: () -> Void
    @EnvironmentObject var accessibility: AccessibilityViewModel
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title).font(.system(size: accessibility.dynamicFontSize - 1, weight: .medium))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).tint(color)
    }
}

// MARK: - Saved Order Row

struct SavedOrderRowView: View {
    let saved: SavedOrder
    let onTap: () -> Void
    @EnvironmentObject var accessibility: AccessibilityViewModel
    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(saved.name)
                            .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                        if saved.createdByCaretaker {
                            Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(.green)
                        }
                    }
                    Text("\(saved.vendorName) · \(saved.items.count) item\(saved.items.count == 1 ? "" : "s")")
                        .font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill").foregroundStyle(.blue)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(saved.name) from \(saved.vendorName). \(saved.createdByCaretaker ? "Set up by caretaker." : "")")
    }
}

// MARK: - Vendor Menu View

struct VendorMenuView: View {
    let vendor:             Vendor
    let terminal:           Terminal?
    let orderHistory:       [SavedOrder]
    let personalizedOffers: [String]

    @EnvironmentObject var cart:          CartViewModel
    @EnvironmentObject var session:       UserSessionViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @StateObject private var reviewVM = ReviewViewModel()

    @State private var showCheckout    = false
    @State private var showReviews     = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let terminal { terminalBanner(terminal) }
                if !personalizedOffers.isEmpty { offersSection }
                if !orderHistory.isEmpty        { orderHistorySection }

                // Review summary teaser
                reviewSummaryTeaser

                // Menu
                ForEach(vendor.menuCategories) { category in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(category.name)
                            .font(.system(size: accessibility.dynamicFontSize + 2, weight: .bold))
                            .padding(.horizontal)
                        ForEach(category.items) { item in MenuItemRowView(item: item) }
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(vendor.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCheckout = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bag.fill")
                        if cart.itemCount > 0 { Text("\(cart.itemCount)").font(.caption.bold()) }
                    }
                }
                .disabled(cart.isEmpty)
                .accessibilityLabel("View cart with \(cart.itemCount) items")
            }
        }
        .navigationDestination(isPresented: $showCheckout) { CheckoutView(vendor: vendor) }
        .navigationDestination(isPresented: $showReviews) {
            VendorReviewsView(vendorID: vendor.id, vendorName: vendor.name)
        }
        .task { await reviewVM.loadReviews(vendorID: vendor.id) }
    }

    @ViewBuilder
    private func terminalBanner(_ terminal: Terminal) -> some View {
        HStack(spacing: 12) {
            Image(systemName: terminal.type.systemImage).font(.system(size: 22)).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(terminal.label).font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                if terminal.queueLength > 0 {
                    Text("\(terminal.queueLength) order\(terminal.queueLength == 1 ? "" : "s") ahead")
                        .font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
                } else {
                    Text("No queue — order now").font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.green)
                }
            }
            Spacer()
            if !terminal.isAcceptingOrders {
                Label("Offline", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding()
        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var offersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Offers for You", systemImage: "tag.fill")
                .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold)).foregroundStyle(.orange).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(personalizedOffers, id: \.self) { offer in
                        Text(offer)
                            .font(.system(size: accessibility.dynamicFontSize - 3))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var orderHistorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Reorder from Previous Visit", systemImage: "clock.arrow.circlepath")
                .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal)
            ForEach(orderHistory.prefix(3)) { saved in
                SavedOrderRowView(saved: saved) {
                    cart.loadFromSavedOrder(saved)
                    showCheckout = true
                }
                .padding(.horizontal)
            }
        }
    }

    private var reviewSummaryTeaser: some View {
        Button { showReviews = true } label: {
            HStack(spacing: 12) {
                if let summary = reviewVM.reviewSummary {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(summary.formattedAverage)
                                .font(.system(size: accessibility.dynamicFontSize + 2, weight: .bold))
                            Text(summary.starDisplay).foregroundStyle(.yellow)
                        }
                        Text("\(summary.totalReviews) verified review\(summary.totalReviews == 1 ? "" : "s")")
                            .font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
                    }
                } else if reviewVM.isLoadingReviews {
                    ProgressView().tint(.secondary)
                    Text("Loading reviews…").font(.system(size: accessibility.dynamicFontSize - 3)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "star.bubble").foregroundStyle(.secondary)
                    Text("See customer reviews").font(.system(size: accessibility.dynamicFontSize - 2)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary).font(.caption)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Menu Item Row View

struct MenuItemRowView: View {
    let item: MenuItem
    @EnvironmentObject var cart:          CartViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
                Text(item.description).font(.system(size: accessibility.dynamicFontSize - 3)).foregroundStyle(.secondary)
                if let cal = item.calories { Text("\(cal) cal").font(.system(size: accessibility.dynamicFontSize - 5)).foregroundStyle(.tertiary) }
                Text(item.formattedPrice).font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold)).foregroundStyle(.blue)
            }
            Spacer()
            Button {
                cart.add(item)
                HapticManager.shared.impact(.light)
            } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 28)).foregroundStyle(.blue)
            }
            .accessibilityLabel("Add \(item.name) to cart")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Checkout View

struct CheckoutView: View {
    let vendor: Vendor
    @EnvironmentObject var cart:          CartViewModel
    @EnvironmentObject var session:       UserSessionViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @StateObject private var orderVM     = OrderViewModel()
    @State private var selectedPayment:  PaymentMethod?
    @State private var showReceipt       = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                orderItemsSection
                Divider()
                if let terminalType = cart.activeTerminalType {
                    terminalContextRow(terminalType)
                    Divider()
                }
                paymentSection
                Divider()
                totalSection
                if let error = orderVM.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: accessibility.dynamicFontSize - 2))
                        .multilineTextAlignment(.center)
                }
                placeOrderButton
            }
            .padding()
        }
        .navigationTitle("Checkout")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showReceipt) {
            if let receipt = orderVM.receipt {
                ReceiptView(receipt: receipt, posAcknowledgement: orderVM.posAcknowledgement)
            }
        }
        .onChange(of: orderVM.orderState) { _, state in
            if case .completed = state {
                if let order = orderVM.receipt?.order {
                    session.addPoints(for: order)
                    session.addToHistory(order)
                }
                cart.clear()
                showReceipt = true
            }
        }
    }

    private var orderItemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your Order").font(.system(size: accessibility.dynamicFontSize + 2, weight: .bold))
            ForEach(cart.items) { item in
                HStack {
                    Text("\(item.quantity)×").foregroundStyle(.secondary)
                    Text(item.menuItem.name)
                    Spacer()
                    Text(String(format: "$%.2f", Double(item.subtotalCents) / 100.0))
                }
                .font(.system(size: accessibility.dynamicFontSize - 1))
            }
        }
    }

    @ViewBuilder
    private func terminalContextRow(_ terminalType: TerminalType) -> some View {
        HStack(spacing: 10) {
            Image(systemName: terminalType.systemImage).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(terminalType.rawValue).font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                Text("Order type set automatically from NFC tap").font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var paymentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Payment").font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
            let methods: [PaymentMethod] = [
                .applePay,
                .creditCard(last4: "4242", brand: "Visa"),
                .splingWallet(balance: 1250)
            ]
            ForEach(methods) { method in
                Button {
                    selectedPayment = method
                    HapticManager.shared.selection()
                } label: {
                    HStack {
                        Image(systemName: method.systemImage)
                        Text(method.displayName).font(.system(size: accessibility.dynamicFontSize - 1))
                        Spacer()
                        if selectedPayment?.id == method.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                        }
                    }
                    .padding(12)
                    .background(
                        selectedPayment?.id == method.id ? Color.blue.opacity(0.1) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(method.displayName)
                .accessibilityAddTraits(selectedPayment?.id == method.id ? .isSelected : [])
            }
        }
    }

    private var totalSection: some View {
        HStack {
            Text("Total").font(.system(size: accessibility.dynamicFontSize + 2, weight: .bold))
            Spacer()
            Text(cart.formattedTotal).font(.system(size: accessibility.dynamicFontSize + 2, weight: .bold)).foregroundStyle(.blue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Total: \(cart.formattedTotal)")
    }

    private var placeOrderButton: some View {
        Button {
            guard let payment = selectedPayment else { return }
            HapticManager.shared.impact()
            let order = cart.asOrder()
            Task { await orderVM.submit(order: order, paymentMethod: payment, posInfo: vendor.posInfo) }
        } label: {
            Group {
                switch orderVM.orderState {
                case .submitting:        ProgressView("Submitting order…").tint(.white)
                case .processingPayment: ProgressView("Processing payment…").tint(.white)
                case .routingToPOS:      ProgressView("Sending to kitchen…").tint(.white)
                default:
                    Text("Place Order · \(cart.formattedTotal)")
                        .font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(
            selectedPayment == nil || cart.isEmpty ||
            orderVM.orderState == .submitting ||
            orderVM.orderState == .processingPayment ||
            orderVM.orderState == .routingToPOS
        )
        .accessibilityLabel("Place order for \(cart.formattedTotal)")
        .accessibilityHint(selectedPayment == nil ? "Select a payment method first" : "")
    }
}

// MARK: - Receipt View

struct ReceiptView: View {
    let receipt:            Receipt
    let posAcknowledgement: POSAcknowledgement?
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @EnvironmentObject var session:       UserSessionViewModel
    @State private var showReview = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 60)).foregroundStyle(.green)
                    Text("Order Confirmed!").font(.system(size: accessibility.dynamicFontSize + 8, weight: .bold))
                    Text("Your order is being prepared.").foregroundStyle(.secondary).font(.system(size: accessibility.dynamicFontSize))
                }
                .padding()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Order confirmed. Your order at \(receipt.vendorName) is being prepared.")

                if let ack = posAcknowledgement { posAckCard(ack) }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(receipt.vendorName).font(.system(size: accessibility.dynamicFontSize + 2, weight: .bold))
                    ForEach(receipt.order.items) { item in
                        HStack {
                            Text("\(item.quantity)× \(item.menuItem.name)")
                            Spacer()
                            Text(String(format: "$%.2f", Double(item.subtotalCents) / 100.0)).foregroundStyle(.secondary)
                        }
                        .font(.system(size: accessibility.dynamicFontSize - 1))
                    }
                    Divider()
                    HStack {
                        Text("Total").font(.system(size: accessibility.dynamicFontSize, weight: .bold))
                        Spacer()
                        Text(receipt.order.formattedTotal).font(.system(size: accessibility.dynamicFontSize, weight: .bold))
                    }
                }
                .padding(.horizontal)

                if let terminalType = receipt.order.terminalType {
                    Label("Ordered via \(terminalType.rawValue)", systemImage: terminalType.systemImage)
                        .font(.system(size: accessibility.dynamicFontSize - 3)).foregroundStyle(.secondary)
                }
                if receipt.pointsEarned > 0 {
                    Label("You earned \(receipt.pointsEarned) Spling points!", systemImage: "star.fill")
                        .font(.system(size: accessibility.dynamicFontSize - 1)).foregroundStyle(.orange)
                }

                // Review CTA — only show if not already reviewed
                if !session.hasReviewed(orderID: receipt.order.id) {
                    Button("Leave a Review") { showReview = true }
                        .buttonStyle(.borderedProminent).tint(.purple).padding(.horizontal)
                        .accessibilityLabel("Leave a review for \(receipt.vendorName)")
                }
            }
            .padding()
        }
        .navigationTitle("Receipt")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showReview) {
            WriteReviewView(order: receipt.order)
                .environmentObject(accessibility)
                .environmentObject(session)
        }
    }

    @ViewBuilder
    private func posAckCard(_ ack: POSAcknowledgement) -> some View {
        HStack(spacing: 24) {
            VStack(spacing: 4) {
                Text(ack.pickupReference).font(.system(size: accessibility.dynamicFontSize + 14, weight: .bold)).foregroundStyle(.blue)
                Text("Pickup Code").font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
            }
            Divider().frame(height: 50)
            VStack(spacing: 4) {
                Text("#\(ack.queuePosition)").font(.system(size: accessibility.dynamicFontSize + 10, weight: .bold))
                Text("Queue Position").font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
            }
            Divider().frame(height: 50)
            VStack(spacing: 4) {
                Text("~\(ack.estimatedReadyMinutes) min").font(.system(size: accessibility.dynamicFontSize + 4, weight: .semibold))
                Text("Est. Ready").font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pickup code \(ack.pickupReference). Queue position \(ack.queuePosition). Ready in about \(ack.estimatedReadyMinutes) minutes.")
    }
}

// MARK: - Write Review View

struct WriteReviewView: View {
    let order: Order
    @StateObject private var vm = ReviewViewModel()
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @EnvironmentObject var session:       UserSessionViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 6) {
                        Image(systemName: "star.bubble.fill").font(.system(size: 44)).foregroundStyle(.purple)
                        Text("Review \(order.vendorName)")
                            .font(.system(size: accessibility.dynamicFontSize + 4, weight: .bold))
                        Text("Your verified order review helps others make better choices.")
                            .font(.system(size: accessibility.dynamicFontSize - 3)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top)

                    // Star rating
                    VStack(spacing: 8) {
                        Text("Overall Rating")
                            .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            ForEach(1...5, id: \.self) { star in
                                Button {
                                    vm.rating = star
                                    HapticManager.shared.selection()
                                } label: {
                                    Image(systemName: star <= vm.rating ? "star.fill" : "star")
                                        .font(.system(size: 36))
                                        .foregroundStyle(star <= vm.rating ? .yellow : .gray)
                                }
                                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                                .accessibilityAddTraits(star == vm.rating ? .isSelected : [])
                            }
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    // Title
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Review Title", systemImage: "text.cursor")
                            .font(.system(size: accessibility.dynamicFontSize - 2, weight: .semibold)).foregroundStyle(.secondary)
                        TextField("Summarise your experience", text: $vm.title)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: accessibility.dynamicFontSize))
                            .accessibilityLabel("Review title")
                    }

                    // Body
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Your Review", systemImage: "square.and.pencil")
                                .font(.system(size: accessibility.dynamicFontSize - 2, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(vm.characterCount)/\(AppConfig.Reviews.maxBodyLength)")
                                .font(.system(size: accessibility.dynamicFontSize - 4))
                                .foregroundStyle(vm.isOverLimit ? .red : .tertiary)
                        }
                        TextField("Tell others what was great (or not) about your order…",
                                  text: $vm.body, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(4...8)
                            .font(.system(size: accessibility.dynamicFontSize))
                            .accessibilityLabel("Review body")
                        if vm.isOverLimit {
                            Text("Too long — please shorten your review.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }

                    // Anonymous toggle
                    Toggle(isOn: $vm.isAnonymous) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Post Anonymously")
                                .font(.system(size: accessibility.dynamicFontSize - 1, weight: .medium))
                            Text("Your name won't appear on this review.")
                                .font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                    // Verified badge info
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        Text("This review will be marked as a **verified order** because it's linked to your actual purchase.")
                            .font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    // Submit
                    Group {
                        switch vm.state {
                        case .idle, .failed:
                            Button {
                                Task {
                                    await vm.submitReview(
                                        order:       order,
                                        authorName:  session.profile.displayName.isEmpty ? "Spling User" : session.profile.displayName,
                                        sessionVM:   session
                                    )
                                }
                            } label: {
                                Text("Submit Review")
                                    .font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.purple)
                            .controlSize(.large)
                            .disabled(!vm.canSubmit)

                        case .submitting:
                            ProgressView("Submitting review…")
                                .frame(maxWidth: .infinity)

                        case .submitted:
                            VStack(spacing: 10) {
                                Label("Review submitted!", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
                                Text("Thank you for helping the community.")
                                    .font(.system(size: accessibility.dynamicFontSize - 3)).foregroundStyle(.secondary)
                            }
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
                            }
                        }
                    }

                    if case .failed(let msg) = vm.state {
                        Text(msg).foregroundStyle(.red).font(.caption).multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .navigationTitle("Write a Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Vendor Reviews View

struct VendorReviewsView: View {
    let vendorID:   String
    let vendorName: String
    @StateObject private var vm = ReviewViewModel()
    @EnvironmentObject var accessibility: AccessibilityViewModel

    var body: some View {
        Group {
            if vm.isLoadingReviews {
                ProgressView("Loading reviews…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.vendorReviews.isEmpty {
                ContentUnavailableView(
                    "No Reviews Yet",
                    systemImage: "star.slash",
                    description: Text("Be the first to review \(vendorName) after your order.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        if let summary = vm.reviewSummary { reviewSummaryCard(summary) }
                        ForEach(vm.vendorReviews) { review in
                            ReviewCardView(review: review) {
                                Task { await vm.markHelpful(review: review) }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("\(vendorName) Reviews")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadReviews(vendorID: vendorID) }
    }

    private func reviewSummaryCard(_ summary: VendorReviewSummary) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 20) {
                VStack(spacing: 4) {
                    Text(summary.formattedAverage)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                    Text(summary.starDisplay).foregroundStyle(.yellow).font(.title2)
                    Text("\(summary.totalReviews) review\(summary.totalReviews == 1 ? "" : "s")")
                        .font(.system(size: accessibility.dynamicFontSize - 3)).foregroundStyle(.secondary)
                }
                Divider().frame(height: 80)
                VStack(spacing: 4) {
                    ForEach([5,4,3,2,1], id: \.self) { star in
                        HStack(spacing: 6) {
                            Text("\(star)").font(.caption2).frame(width: 10)
                            GeometryReader { geo in
                                let count  = summary.distribution[star] ?? 0
                                let ratio  = summary.totalReviews > 0 ? Double(count) / Double(summary.totalReviews) : 0
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4).fill(Color(.systemGray5)).frame(height: 8)
                                    RoundedRectangle(cornerRadius: 4).fill(Color.yellow).frame(width: geo.size.width * ratio, height: 8)
                                }
                            }
                            .frame(height: 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.formattedAverage) out of 5 stars from \(summary.totalReviews) reviews")
    }
}

// MARK: - Review Card View

struct ReviewCardView: View {
    let review:        Review
    let onMarkHelpful: () -> Void
    @EnvironmentObject var accessibility: AccessibilityViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.title)
                        .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= review.rating ? "star.fill" : "star")
                                .font(.system(size: 12))
                                .foregroundStyle(star <= review.rating ? .yellow : .gray)
                        }
                    }
                }
                Spacer()
                if review.isVerifiedOrder {
                    Label("Verified", systemImage: "checkmark.seal.fill")
                        .font(.system(size: accessibility.dynamicFontSize - 5, weight: .medium))
                        .foregroundStyle(.green)
                }
            }

            Text(review.body)
                .font(.system(size: accessibility.dynamicFontSize - 2))
                .foregroundStyle(.primary)
                .lineLimit(6)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(review.authorName)
                        .font(.system(size: accessibility.dynamicFontSize - 4, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(review.createdAt, style: .date)
                        .font(.system(size: accessibility.dynamicFontSize - 5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    onMarkHelpful()
                    HapticManager.shared.impact(.light)
                } label: {
                    Label("\(review.helpfulCount) helpful", systemImage: "hand.thumbsup")
                        .font(.system(size: accessibility.dynamicFontSize - 4))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(review.title). \(review.rating) stars. \(review.body). By \(review.authorName). \(review.isVerifiedOrder ? "Verified order." : "")")
    }
}

// MARK: - Saved Orders View

struct SavedOrdersView: View {
    @EnvironmentObject var session:       UserSessionViewModel
    @EnvironmentObject var cart:          CartViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @State private var showMenu = false

    var body: some View {
        Group {
            if session.profile.savedOrders.isEmpty {
                ContentUnavailableView(
                    "No Saved Orders",
                    systemImage: "star.slash",
                    description: Text("Save an order from the checkout screen to reorder quickly.")
                )
            } else {
                List {
                    ForEach(session.profile.savedOrders) { saved in
                        SavedOrderRowView(saved: saved) {
                            cart.loadFromSavedOrder(saved)
                            showMenu = true
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                    .onDelete { indexSet in
                        indexSet.map { session.profile.savedOrders[$0].id }.forEach {
                            session.deleteSavedOrder(id: $0)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Saved Orders")
        .navigationDestination(isPresented: $showMenu) {
            if !cart.vendorName.isEmpty {
                // In production load full VendorMenuView; for now show a placeholder
                Text("Menu for \(cart.vendorName)")
            }
        }
    }
}

// MARK: - Caretaker Setup View

struct CaretakerSetupView: View {
    @EnvironmentObject var session:       UserSessionViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @State private var orderName  = ""
    @State private var vendorID   = ""
    @State private var vendorName = ""
    @State private var isSaved    = false

    var body: some View {
        Form {
            Section(header: Text("Order Details").font(.system(size: accessibility.dynamicFontSize - 2))) {
                TextField("Order name (e.g. 'Lunch at Tim Hortons')", text: $orderName)
                    .font(.system(size: accessibility.dynamicFontSize))
                TextField("Vendor name", text: $vendorName)
                    .font(.system(size: accessibility.dynamicFontSize))
            }
            Section(header: Text("About Caretaker Mode").font(.system(size: accessibility.dynamicFontSize - 2))) {
                Text("Set up an order in advance. The person you care for can then confirm and transmit via NFC.")
                    .font(.system(size: accessibility.dynamicFontSize - 2)).foregroundStyle(.secondary)
            }
            Section {
                Button("Save Order for User") {
                    guard !orderName.isEmpty, !vendorName.isEmpty else { return }
                    let saved = SavedOrder(
                        name:               orderName,
                        vendorID:           vendorID.isEmpty ? UUID().uuidString : vendorID,
                        vendorName:         vendorName,
                        items:              [],
                        createdByCaretaker: true
                    )
                    session.saveOrder(saved)
                    HapticManager.shared.notification(.success)
                    isSaved = true
                }
                .disabled(orderName.isEmpty || vendorName.isEmpty)
            }
            if isSaved {
                Section {
                    Label("Order saved successfully!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: accessibility.dynamicFontSize - 1))
                }
            }
        }
        .navigationTitle("Caretaker Setup")
    }
}

// MARK: - Accessibility Settings View

struct AccessibilitySettingsView: View {
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @EnvironmentObject var session:       UserSessionViewModel

    var body: some View {
        Form {
            Section("Voice & Audio") {
                Toggle("Voice Guidance",   isOn: $accessibility.settings.voiceGuidanceEnabled)
                Toggle("Haptic Feedback",  isOn: $accessibility.settings.hapticFeedbackEnabled)
            }
            Section("Visual") {
                Toggle("High Contrast",    isOn: $accessibility.settings.highContrastEnabled)
                Toggle("Reduce Motion",    isOn: $accessibility.settings.reducedMotionEnabled)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Text Size: \(Int(accessibility.settings.fontSize))pt")
                    Slider(
                        value: $accessibility.settings.fontSize,
                        in:    AppConfig.Accessibility.minimumTextSize...AppConfig.Accessibility.maximumTextSize,
                        step:  1
                    )
                }
            }
            Section("Caretaker Mode") {
                Toggle("Enable Caretaker Mode", isOn: $accessibility.settings.caretakerModeEnabled)
                if accessibility.settings.caretakerModeEnabled {
                    TextField("Caretaker name", text: $accessibility.settings.caretakerName)
                }
            }
            Section {
                Button("Reset to Defaults", role: .destructive) { accessibility.resetToDefaults() }
            }
        }
        .navigationTitle("Accessibility")
    }
}

// MARK: - Order Prioritization View

struct OrderPrioritizationView: View {
    @StateObject private var vm = OrderPrioritizationViewModel()
    @EnvironmentObject var accessibility: AccessibilityViewModel

    var body: some View {
        VStack {
            if vm.prioritizedOrders.isEmpty {
                ContentUnavailableView(
                    "No Active Orders",
                    systemImage: "tray",
                    description: Text("Add sample orders to see how AI prioritization works.")
                )
            } else {
                List(vm.prioritizedOrders) { order in
                    HStack(spacing: 12) {
                        Image(systemName: order.channel.systemImage).frame(width: 24).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(order.channel.rawValue)
                                    .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                                if order.placedByCaretaker {
                                    Image(systemName: "figure.roll").font(.caption).foregroundStyle(.green)
                                }
                            }
                            Text(order.placedAt, style: .time)
                                .font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        priorityLabel(order.channel.priority)
                    }
                }
                .listStyle(.plain)
            }
            HStack(spacing: 12) {
                Button("Add Samples") { vm.addSampleOrders() }.buttonStyle(.borderedProminent)
                if !vm.orders.isEmpty {
                    Button("Clear", role: .destructive) { vm.orders.removeAll() }.buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .navigationTitle("Order Queue")
    }

    private func priorityLabel(_ priority: Int) -> some View {
        let (label, color): (String, Color) = switch priority {
        case 0: ("High",   .red)
        case 1: ("Medium", .orange)
        default: ("Low",   .green)
        }
        return Text(label)
            .font(.system(size: accessibility.dynamicFontSize - 5, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Order History View

struct OrderHistoryView: View {
    @EnvironmentObject var session:       UserSessionViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel

    var body: some View {
        Group {
            if session.profile.orderHistory.isEmpty {
                ContentUnavailableView("No Orders Yet", systemImage: "bag",
                    description: Text("Your completed orders will appear here."))
            } else {
                List(session.profile.orderHistory) { order in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(order.vendorName)
                                .font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
                            Spacer()
                            Text(order.formattedTotal)
                                .font(.system(size: accessibility.dynamicFontSize - 1)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Label(order.channel.rawValue, systemImage: order.channel.systemImage)
                                .font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
                            Text("·")
                            Text(order.placedAt, style: .date)
                                .font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Text(order.status.rawValue)
                                .font(.system(size: accessibility.dynamicFontSize - 5, weight: .medium))
                                .foregroundStyle(.green)
                            if session.hasReviewed(orderID: order.id) {
                                Label("Reviewed", systemImage: "star.fill")
                                    .font(.system(size: accessibility.dynamicFontSize - 6))
                                    .foregroundStyle(.purple)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Order History")
    }
}

// MARK: - Loyalty View

struct LoyaltyView: View {
    @EnvironmentObject var session:       UserSessionViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel
    var account: LoyaltyAccount { session.profile.loyaltyAccount }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "trophy.fill").font(.system(size: 64)).foregroundStyle(tierColor(account.tier))
                    Text(account.tier.rawValue).font(.system(size: accessibility.dynamicFontSize + 10, weight: .bold))
                    Text("\(account.points) points").font(.system(size: accessibility.dynamicFontSize + 2)).foregroundStyle(.secondary)
                    if let next = account.pointsToNextTier {
                        Text("\(next) points to next tier").font(.system(size: accessibility.dynamicFontSize - 2)).foregroundStyle(.tertiary)
                        ProgressView(
                            value: Double(account.points - account.tier.minimumPoints),
                            total: Double(next + account.points - account.tier.minimumPoints)
                        )
                        .padding(.horizontal, 40)
                    }
                }
                .padding()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(account.tier.rawValue) member with \(account.points) points")

                Divider()

                if account.transactions.isEmpty {
                    Text("Earn points by placing orders through Spling.")
                        .foregroundStyle(.secondary).font(.system(size: accessibility.dynamicFontSize - 2))
                        .multilineTextAlignment(.center).padding()
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recent Activity").font(.system(size: accessibility.dynamicFontSize, weight: .bold)).padding(.horizontal)
                        ForEach(account.transactions) { tx in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tx.vendorName).font(.system(size: accessibility.dynamicFontSize - 1))
                                    Text(tx.date, style: .date).font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("+\(tx.pointsEarned) pts").font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold)).foregroundStyle(.orange)
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Rewards")
    }

    private func tierColor(_ tier: LoyaltyTier) -> Color {
        switch tier { case .bronze: return .brown; case .silver: return .gray; case .gold: return .yellow; case .platinum: return .purple }
    }
}

// MARK: - Profile View

struct ProfileView: View {
    @EnvironmentObject var session:       UserSessionViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @State private var showSignOutConfirm = false
    @State private var showAPIKeyEntry    = false
    @State private var apiKeyDraft        = ""

    var body: some View {
        Form {
            Section("Account") {
                HStack {
                    Image(systemName: "person.circle.fill").font(.system(size: 40)).foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(session.profile.displayName.isEmpty ? "Spling User" : session.profile.displayName)
                            .font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
                        Text(session.profile.loyaltyAccount.tier.rawValue + " Member")
                            .foregroundStyle(.secondary).font(.system(size: accessibility.dynamicFontSize - 3))
                    }
                }
            }
            Section("Accessibility") {
                NavigationLink(destination: AccessibilitySettingsView()) {
                    Label("Accessibility Settings", systemImage: "accessibility")
                }
            }
            Section("Orders") {
                NavigationLink(destination: OrderHistoryView()) {
                    Label("Order History", systemImage: "bag")
                }
                NavigationLink(destination: SavedOrdersView()) {
                    Label("Saved Orders", systemImage: "star.fill")
                }
            }
            Section("My Reviews") {
                NavigationLink(destination: MyReviewsView()) {
                    Label("Reviews I've Written", systemImage: "star.bubble")
                }
            }
            Section("Developer") {
                Button("Set API Key") { showAPIKeyEntry = true }
                    .foregroundStyle(.blue)
            }
            Section {
                Button("Sign Out", role: .destructive) { showSignOutConfirm = true }
            }
        }
        .navigationTitle("Profile")
        .confirmationDialog("Sign out of Spling?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { session.signOut() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Set Anthropic API Key", isPresented: $showAPIKeyEntry) {
            SecureField("sk-ant-…", text: $apiKeyDraft)
            Button("Save") {
                if !apiKeyDraft.isEmpty {
                    KeychainManager.shared.anthropicAPIKey = apiKeyDraft
                    apiKeyDraft = ""
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your key is stored securely in the device Keychain and never leaves this device.")
        }
    }
}

// MARK: - My Reviews View

struct MyReviewsView: View {
    @EnvironmentObject var session:       UserSessionViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel

    var body: some View {
        Group {
            if session.profile.reviews.isEmpty {
                ContentUnavailableView(
                    "No Reviews Yet",
                    systemImage: "star.slash",
                    description: Text("After completing an order you'll be invited to leave a review.")
                )
            } else {
                List(session.profile.reviews) { review in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(review.vendorName).font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                            Spacer()
                            HStack(spacing: 2) {
                                ForEach(1...5, id: \.self) { star in
                                    Image(systemName: star <= review.rating ? "star.fill" : "star")
                                        .font(.system(size: 11))
                                        .foregroundStyle(star <= review.rating ? .yellow : .gray)
                                }
                            }
                        }
                        Text(review.title).font(.system(size: accessibility.dynamicFontSize - 2, weight: .medium))
                        Text(review.body).font(.system(size: accessibility.dynamicFontSize - 3)).foregroundStyle(.secondary).lineLimit(3)
                        HStack {
                            Text(review.createdAt, style: .date).font(.caption).foregroundStyle(.tertiary)
                            if review.isVerifiedOrder {
                                Label("Verified", systemImage: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("My Reviews")
    }
}

// MARK: - Rating View (quick post-order star only)

struct RatingView: View {
    let orderID: UUID
    @StateObject private var vm = RatingViewModel()
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("How was your order?").font(.system(size: accessibility.dynamicFontSize + 4, weight: .bold))
                HStack(spacing: 16) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            vm.rating = star
                            HapticManager.shared.selection()
                        } label: {
                            Image(systemName: star <= vm.rating ? "star.fill" : "star")
                                .font(.system(size: 36))
                                .foregroundStyle(star <= vm.rating ? .yellow : .gray)
                        }
                        .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                        .accessibilityAddTraits(star == vm.rating ? .isSelected : [])
                    }
                }
                TextField("Additional feedback (optional)", text: $vm.feedback, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3...5)
                    .font(.system(size: accessibility.dynamicFontSize)).padding(.horizontal)
                Group {
                    switch vm.state {
                    case .idle, .failed:
                        Button("Submit") { Task { await vm.submit(for: orderID) } }
                            .buttonStyle(.borderedProminent)
                    case .submitting:
                        ProgressView("Submitting…")
                    case .submitted:
                        Label("Thanks for your feedback!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
                            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() } }
                    }
                }
                if case .failed(let msg) = vm.state {
                    Text(msg).foregroundStyle(.red).font(.caption)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Rate Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss() } } }
        }
    }
}

// MARK: - AI Menu View

struct AIMenuView: View {
    @StateObject private var vm = AIMenuViewModel()
    @EnvironmentObject var cart:          CartViewModel
    @EnvironmentObject var session:       UserSessionViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @Environment(\.dismiss) var dismiss
    @State private var showMenu = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    inputSection
                    statusSection
                    if let result = vm.result { resultSection(result) }
                }
                .padding()
            }
            .navigationTitle("Add Vendor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .navigationDestination(isPresented: $showMenu) {
                if let result = vm.result { AIMenuBrowseView(cache: result) }
            }
        }
    }

    private var headerSection: some View {
        VStack(spacing: 10) {
            Image(systemName: "brain.head.profile").font(.system(size: 48)).foregroundStyle(.purple)
            Text("AI Menu Reader").font(.system(size: accessibility.dynamicFontSize + 6, weight: .bold))
            Text("Paste any restaurant or store website and the AI will read the menu and prices for you.")
                .font(.system(size: accessibility.dynamicFontSize - 2)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Restaurant Website", systemImage: "link")
                    .font(.system(size: accessibility.dynamicFontSize - 2, weight: .semibold)).foregroundStyle(.secondary)
                TextField("e.g. timhortons.com/menu", text: $vm.urlText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .font(.system(size: accessibility.dynamicFontSize))
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Vendor Name (optional)", systemImage: "storefront")
                    .font(.system(size: accessibility.dynamicFontSize - 2, weight: .semibold)).foregroundStyle(.secondary)
                TextField("e.g. Tim Hortons", text: $vm.vendorNameText)
                    .textFieldStyle(.roundedBorder).font(.system(size: accessibility.dynamicFontSize))
            }
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                vm.scrape()
            } label: {
                Group {
                    if vm.isLoading {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text(vm.state == .fetching ? "Loading site…" : "AI reading menu…")
                        }
                    } else {
                        Label("Read Menu with AI", systemImage: "sparkles")
                    }
                }
                .frame(maxWidth: .infinity)
                .font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
            }
            .buttonStyle(.borderedProminent).tint(.purple).controlSize(.large)
            .disabled(vm.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vm.isLoading)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if vm.isLoading {
            VStack(spacing: 12) {
                ProgressView().scaleEffect(1.3)
                Text(vm.statusLabel).font(.system(size: accessibility.dynamicFontSize - 2)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("This takes 5–15 seconds depending on the site size.")
                    .font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
            .padding()
        } else if case .failed(let msg) = vm.state {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 32)).foregroundStyle(.orange)
                Text(msg).font(.system(size: accessibility.dynamicFontSize - 2)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Try Again") { vm.scrape() }.buttonStyle(.bordered).tint(.orange)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func resultSection(_ result: ScrapedMenuCache) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.vendorName).font(.system(size: accessibility.dynamicFontSize + 2, weight: .bold))
                        Text("\(result.categories.count) categor\(result.categories.count == 1 ? "y" : "ies")")
                            .font(.system(size: accessibility.dynamicFontSize - 3)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    confidenceBadge(result.confidence)
                }
                if let notes = result.notes, !notes.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue).font(.caption)
                        Text(notes).font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                let preview = result.categories.flatMap(\.items).prefix(3)
                if !preview.isEmpty {
                    Divider()
                    VStack(spacing: 4) {
                        ForEach(preview) { item in
                            HStack {
                                Text(item.name).font(.system(size: accessibility.dynamicFontSize - 3)).lineLimit(1)
                                Spacer()
                                Text(item.priceCents == 0 ? "Price unavailable" : item.formattedPrice)
                                    .font(.system(size: accessibility.dynamicFontSize - 3, weight: .semibold))
                                    .foregroundStyle(item.priceCents == 0 ? .secondary : .primary)
                            }
                        }
                        let total = result.categories.flatMap(\.items).count
                        if total > 3 {
                            Text("+ \(total - 3) more items").font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 12) {
                Button {
                    cart.vendorID   = UUID().uuidString
                    cart.vendorName = result.vendorName
                    showMenu        = true
                } label: {
                    Label("Browse & Order", systemImage: "cart.fill")
                        .frame(maxWidth: .infinity)
                        .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                }
                .buttonStyle(.borderedProminent).tint(.blue)

                Button { vm.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 18))
                }
                .buttonStyle(.bordered).tint(.secondary)
                .accessibilityLabel("Refresh menu")
            }

            Text("Menu last read \(result.scrapedAt, style: .relative) ago · refreshes after 24 hours")
                .font(.system(size: accessibility.dynamicFontSize - 5)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
    }

    private func confidenceBadge(_ confidence: String) -> some View {
        let (label, color): (String, Color) = switch confidence {
        case "high":   ("✓ High accuracy", .green)
        case "medium": ("~ Partial data",  .orange)
        default:       ("⚠ Low confidence", .red)
        }
        return Text(label)
            .font(.system(size: accessibility.dynamicFontSize - 5, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - AI Menu Browse View

struct AIMenuBrowseView: View {
    let cache: ScrapedMenuCache
    @EnvironmentObject var cart:          CartViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @State private var showCheckout = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                extractionBanner
                ForEach(cache.categories) { category in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(category.name)
                            .font(.system(size: accessibility.dynamicFontSize + 2, weight: .bold))
                            .padding(.horizontal)
                        ForEach(category.items) { item in AIMenuItemRow(item: item) }
                    }
                }
                if cache.categories.isEmpty {
                    ContentUnavailableView(
                        "No Menu Items Found",
                        systemImage: "doc.questionmark",
                        description: Text("The AI couldn't extract items from this page. Try linking directly to the /menu page.")
                    )
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(cache.vendorName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCheckout = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bag.fill")
                        if cart.itemCount > 0 { Text("\(cart.itemCount)").font(.caption.bold()) }
                    }
                }
                .disabled(cart.isEmpty)
            }
        }
        .navigationDestination(isPresented: $showCheckout) {
            CheckoutView(vendor: Vendor(id: UUID().uuidString, name: cache.vendorName, menuCategories: cache.categories))
        }
    }

    private var extractionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile").foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Menu read by AI from \(cache.vendorURL)")
                    .font(.system(size: accessibility.dynamicFontSize - 4)).foregroundStyle(.secondary).lineLimit(1)
                if let notes = cache.notes, !notes.isEmpty {
                    Text(notes).font(.system(size: accessibility.dynamicFontSize - 5)).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - AI Menu Item Row

struct AIMenuItemRow: View {
    let item: MenuItem
    @EnvironmentObject var cart:          CartViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
                if !item.description.isEmpty {
                    Text(item.description).font(.system(size: accessibility.dynamicFontSize - 3)).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if item.priceCents > 0 {
                        Text(item.formattedPrice).font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold)).foregroundStyle(.blue)
                    } else {
                        Text("Price not available").font(.system(size: accessibility.dynamicFontSize - 3)).foregroundStyle(.tertiary)
                    }
                    if let cal = item.calories {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(cal) cal").font(.system(size: accessibility.dynamicFontSize - 5)).foregroundStyle(.tertiary)
                    }
                }
                if !item.allergens.isEmpty {
                    Text(item.allergens.joined(separator: ", "))
                        .font(.system(size: accessibility.dynamicFontSize - 5)).foregroundStyle(.orange.opacity(0.8))
                }
            }
            Spacer()
            Button {
                cart.add(item)
                HapticManager.shared.impact(.light)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(item.priceCents > 0 ? .blue : .gray)
            }
            .disabled(item.priceCents == 0)
            .accessibilityLabel(item.priceCents > 0
                ? "Add \(item.name) for \(item.formattedPrice) to cart"
                : "\(item.name) — price unavailable, cannot add to cart")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(UserSessionViewModel())
        .environmentObject(AccessibilityViewModel())
        .environmentObject(CartViewModel())
}
