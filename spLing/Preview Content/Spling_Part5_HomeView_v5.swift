// ============================================================
// SPLING — FULL STACK v5
// HomeView_v5.swift
//
// REPLACE the existing HomeView struct in Views.swift with this.
// ADD the UserSessionViewModel extensions to ViewModels.swift.
// ============================================================
import SwiftUI
import AVFoundation

// ─────────────────────────────────────────────────────────────
// MARK: - Home View (REPLACE existing HomeView in Views.swift)
// ─────────────────────────────────────────────────────────────

struct HomeView: View {
    @EnvironmentObject var session: UserSessionViewModel
    @EnvironmentObject var cart: CartViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel

    // Existing managers
    @StateObject private var nfcManager = NFCManager()
    @StateObject private var vendorVM = VendorViewModel()

    // QR + AI pipeline
    @StateObject private var qrCoordinator = VendorContextCoordinator()
    @State private var showQRScanner = false
    @State private var isLoadingVendorFromQR = false
    @State private var qrParseErrorMessage: String?
    @State private var showQRParseError = false

    // Accessibility pathway sheets
    @State private var showAdaptiveSpeech = false
    @State private var showPictureMenu = false
    @State private var showCaregiverProgram = false
    @State private var showCaregiverPickupAlert = false
    @State private var pendingCaregiverOrder: CaregiverProgrammedOrder?

    // Existing navigation flags
    @State private var showVendorMenu = false
    @State private var showSavedOrders = false
    @State private var showOrderPrioritization = false
    @State private var showAIMenuEntry = false

    // Error flags
    @State private var nfcErrorMessage: String?
    @State private var showNFCError = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                greetingHeader
                loyaltyCard

                // Caregiver pickup banner (highest priority)
                if let order = session.pendingCaregiverPickupOrder {
                    caregiverPickupBanner(order: order)
                }

                quickActions
                accessibilityPathwayCards

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

        // ── Navigation destinations ──────────────────────────
        .navigationDestination(isPresented: $showVendorMenu) {
            if let vendor = vendorVM.vendor {
                VendorMenuView(vendor: vendor,
                               terminal: vendorVM.detectedTerminal,
                               orderHistory: vendorVM.orderHistoryAtVendor,
                               personalizedOffers: vendorVM.personalizedOffers)
            }
        }
        .navigationDestination(isPresented: $showSavedOrders) { SavedOrdersView() }
        .navigationDestination(isPresented: $showOrderPrioritization) { OrderPrioritizationView() }

        // ── QR Scanner sheet ─────────────────────────────────
        .sheet(isPresented: $showQRScanner) {
            QRScannerView(
                onScan: handleQRScan,
                onDismiss: { showQRScanner = false }
            )
            .environmentObject(accessibility)
        }

        // ── AI menu entry sheet ──────────────────────────────
        .sheet(isPresented: $showAIMenuEntry) {
            AIMenuView()
                .environmentObject(accessibility)
                .environmentObject(cart)
                .environmentObject(session)
        }

        // ── Adaptive Speech sheet ────────────────────────────
        .sheet(isPresented: $showAdaptiveSpeech) {
            if let vendor = vendorVM.vendor {
                AdaptiveSpeechView(
                    menuItems: vendor.menuCategories.flatMap(\.items),
                    voiceProfile: session.voiceMLProfile,
                    onConfirm: { item, updatedProfile in
                        cart.add(item)
                        session.updateVoiceMLProfile(updatedProfile)
                        showAdaptiveSpeech = false
                        showVendorMenu = true
                    },
                    onDismiss: { showAdaptiveSpeech = false }
                )
                .environmentObject(accessibility)
            } else {
                Text("Load a vendor menu first via QR or NFC.")
                    .padding()
            }
        }

        // ── Picture Menu sheet ───────────────────────────────
        .sheet(isPresented: $showPictureMenu) {
            if let vendor = vendorVM.vendor {
                PictureMenuView(
                    vendor: vendor,
                    preference: session.pictureMenuPreference,
                    onComplete: { pictureVM in
                        pictureVM.transferToCart(cart)
                        showPictureMenu = false
                        showVendorMenu = true
                    },
                    onDismiss: { showPictureMenu = false }
                )
                .environmentObject(accessibility)
            } else {
                Text("Load a vendor menu first via QR or NFC.")
                    .padding()
            }
        }

        // ── Caregiver Program sheet ──────────────────────────
        .sheet(isPresented: $showCaregiverProgram) {
            CaregiverProgramView()
                .environmentObject(session)
                .environmentObject(accessibility)
        }

        // ── Caregiver Pickup Alert sheet ─────────────────────
        .sheet(isPresented: $showCaregiverPickupAlert) {
            if let order = pendingCaregiverOrder {
                CaregiverPickupAlertView(
                    programmedOrder: order,
                    onGoPickUp: {
                        cart.vendorID = order.vendorID
                        cart.vendorName = order.vendorName
                        for item in order.items { cart.add(item) }
                        showCaregiverPickupAlert = false
                        showVendorMenu = true
                        session.markCaregiverOrderAlertSent(id: order.id)
                    },
                    onDismiss: {
                        showCaregiverPickupAlert = false
                        session.markCaregiverOrderAlertSent(id: order.id)
                    }
                )
                .environmentObject(accessibility)
            }
        }

        // ── onChange handlers ────────────────────────────────
        .onChange(of: qrCoordinator.loadState) { _, state in
            guard state == .loaded else { return }
            isLoadingVendorFromQR = false
            showVendorMenu = true
            if let name = qrCoordinator.pendingVendorName ?? vendorVM.vendor?.name {
                accessibility.announceForVoiceOver("\(name) menu loaded. Ready to order.")
            }
        }
        .onChange(of: qrCoordinator.showError) { _, show in
            guard show else { return }
            isLoadingVendorFromQR = false
        }
        .onChange(of: nfcManager.error) { _, error in
            if let error {
                nfcErrorMessage = error.localizedDescription
                showNFCError = true
                accessibility.announceForVoiceOver("NFC error: \(error.localizedDescription)")
            }
        }
        .onChange(of: nfcManager.detectedPayload) { _, tagPayload in
            guard let tagPayload else { return }
            Task {
                vendorVM.loadMockVendor(from: tagPayload)
                if let vendor = vendorVM.vendor {
                    cart.vendorID = vendor.id
                    cart.vendorName = vendor.name
                    cart.activeTerminalID = tagPayload.terminalID
                    cart.activeTerminalType = tagPayload.terminalType
                    vendorVM.orderHistoryAtVendor = session.savedOrders(for: vendor.id)
                    showVendorMenu = true
                    accessibility.announceForVoiceOver(
                        "Detected \(tagPayload.terminalType.rawValue) at \(vendor.name). Menu loaded."
                    )
                }
            }
        }
        .onAppear {
            if let order = session.pendingCaregiverPickupOrder {
                pendingCaregiverOrder = order
                showCaregiverPickupAlert = true
            }
        }

        // ── Alerts ──────────────────────────────────────────
        .alert("QR Code Error", isPresented: $showQRParseError) {
            Button("Try Again") { showQRScanner = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(qrParseErrorMessage ?? "Could not read QR code.")
        }
        .alert("Couldn't Load Menu", isPresented: $qrCoordinator.showError) {
            Button("Try Again") {
                Task {
                    await qrCoordinator.retry(vendorVM: vendorVM, cart: cart, session: session)
                }
            }
            Button("Cancel", role: .cancel) { qrCoordinator.reset() }
        } message: {
            Text(qrCoordinator.errorMessage ?? "Please try again.")
        }
        .alert("NFC Error", isPresented: $showNFCError) {
            Button("OK") { nfcManager.reset() }
        } message: {
            Text(nfcErrorMessage ?? "An unknown NFC error occurred.")
        }
    }

    // ─────────────────────────────────────────────────────────
    // MARK: - QR Scan Handler
    // ─────────────────────────────────────────────────────────

    private func handleQRScan(_ rawPayload: String) {
        showQRScanner = false
        isLoadingVendorFromQR = true
        qrCoordinator.reset()
        Task {
            do {
                let input = try QRPayloadParser.parse(rawPayload)
                await qrCoordinator.loadVendorFromQR(
                    input: input,
                    vendorVM: vendorVM,
                    cart: cart,
                    session: session
                )
            } catch let parseError as QRParseError {
                qrParseErrorMessage = parseError.localizedDescription
                showQRParseError = true
                isLoadingVendorFromQR = false
                HapticManager.shared.notification(.error)
                accessibility.announceForVoiceOver("QR scan error. \(parseError.localizedDescription)")
            } catch {
                qrParseErrorMessage = error.localizedDescription
                showQRParseError = true
                isLoadingVendorFromQR = false
                HapticManager.shared.notification(.error)
            }
        }
    }

    // ─────────────────────────────────────────────────────────
    // MARK: - Subviews
    // ─────────────────────────────────────────────────────────

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
            Image(systemName: "trophy.fill").font(.system(size: 36))
                .foregroundStyle(tierColor(tier))
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loyalty: \(session.profile.loyaltyAccount.points) points, \(tier.rawValue) tier")
    }

    private func tierColor(_ tier: LoyaltyTier) -> Color {
        switch tier { case .bronze: return .brown; case .silver: return .gray; case .gold: return .yellow; case .platinum: return .purple }
    }

    // MARK: Quick Actions (NFC + QR + Saved + Queue)

    private var quickActions: some View {
        VStack(spacing: 12) {
            // ── NFC Tap to Order ─────────────────────────────
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

            // ── QR Scan → AI menu ────────────────────────────
            Button {
                HapticManager.shared.impact(.medium)
                showQRScanner = true
            } label: {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 2) {
                        if isLoadingVendorFromQR {
                            Text("Loading menu…")
                                .font(.system(size: accessibility.dynamicFontSize + 2, weight: .semibold))
                            if let name = qrCoordinator.pendingVendorName {
                                Text(name)
                                    .font(.system(size: accessibility.dynamicFontSize - 3))
                                    .opacity(0.8)
                            }
                        } else {
                            Text("Scan QR Code")
                                .font(.system(size: accessibility.dynamicFontSize + 2, weight: .semibold))
                            Text("AI reads the menu automatically")
                                .font(.system(size: accessibility.dynamicFontSize - 4)).opacity(0.8)
                        }
                    }
                    Spacer()
                    if isLoadingVendorFromQR {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "sparkles").foregroundStyle(.yellow)
                    }
                }
                .padding().frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(isLoadingVendorFromQR)
            .accessibilityLabel(isLoadingVendorFromQR ? "Loading vendor menu" : "Scan vendor QR code — AI will read the menu")
            .accessibilityHint("Point camera at the QR code near the drive-through terminal")

            // ── Saved Orders + Queue ─────────────────────────
            HStack(spacing: 12) {
                ActionButton(title: "Saved Orders", icon: "star.fill", color: .orange) {
                    showSavedOrders = true
                }
                ActionButton(title: "Order Queue", icon: "list.number", color: .purple) {
                    showOrderPrioritization = true
                }
            }

            // ── Add Vendor by Website (AI) ───────────────────
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

    // MARK: - Three Accessibility Pathway Cards

    private var accessibilityPathwayCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Accessibility Ordering", systemImage: "accessibility")
                .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                .foregroundStyle(.secondary)

            AccessibilityPathwayCard(mode: .adaptiveSpeech, isEnabled: vendorVM.vendor != nil) {
                showAdaptiveSpeech = true
            }

            AccessibilityPathwayCard(mode: .pictureMenu, isEnabled: vendorVM.vendor != nil) {
                showPictureMenu = true
            }

            AccessibilityPathwayCard(mode: .caregiverSetup, isEnabled: true) {
                showCaregiverProgram = true
            }

            if vendorVM.vendor == nil {
                Text("Load a menu via QR or NFC first to use Speech or Picture Menu ordering.")
                    .font(.system(size: accessibility.dynamicFontSize - 4))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
        .padding()
        .background(Color.purple.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Caregiver Pickup Banner

    private func caregiverPickupBanner(order: CaregiverProgrammedOrder) -> some View {
        Button {
            pendingCaregiverOrder = order
            showCaregiverPickupAlert = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "bag.fill.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Order Ready at \(order.vendorName)!")
                        .font(.system(size: accessibility.dynamicFontSize, weight: .bold))
                    Text("Tap to go pick up now")
                        .font(.system(size: accessibility.dynamicFontSize - 3))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding()
            .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Order at \(order.vendorName) is ready. Tap to pick up.")
    }

    // MARK: Caretaker section (legacy)

    private var caretakerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Caretaker Mode", systemImage: "person.2.fill")
                .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                .foregroundStyle(.secondary)

            Button { showCaregiverProgram = true } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Set Up Order for User")
                        .font(.system(size: accessibility.dynamicFontSize))
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

// ─────────────────────────────────────────────────────────────
// MARK: - Accessibility Pathway Card (reusable)
// ─────────────────────────────────────────────────────────────

struct AccessibilityPathwayCard: View {
    let mode: AccessibilityOrderingMode
    let isEnabled: Bool
    let onTap: () -> Void

    @EnvironmentObject var accessibility: AccessibilityViewModel

    private var tintColor: Color {
        switch mode {
        case .adaptiveSpeech: return .purple
        case .pictureMenu:    return .blue
        case .caregiverSetup: return .green
        case .standard:       return .gray
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 26))
                    .foregroundStyle(isEnabled ? tintColor : .gray)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.rawValue)
                        .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                    Text(mode.description)
                        .font(.system(size: accessibility.dynamicFontSize - 4))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            .padding()
            .background(
                isEnabled ? tintColor.opacity(0.08) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("\(mode.rawValue). \(mode.description).\(isEnabled ? "" : " Load a menu first to use this.")")
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - UserSessionViewModel Extensions
// ADD these to ViewModels.swift alongside UserSessionViewModel
// (or leave here — Swift extensions can live in any file)
// ─────────────────────────────────────────────────────────────

extension UserSessionViewModel {

    // MARK: - Voice ML Profile

    var voiceMLProfile: VoiceMLProfile {
        profile.voiceMLProfile ?? VoiceMLProfile(userID: profile.id)
    }

    func updateVoiceMLProfile(_ updated: VoiceMLProfile) {
        profile.voiceMLProfile = updated
        persistProfile()
    }

    func mergeVoicePhrases(_ phrases: [String: String]) {
        var prof = voiceMLProfile
        for (phrase, itemID) in phrases {
            prof.caregiverTrainedPhrases[phrase.lowercased()] = itemID
        }
        profile.voiceMLProfile = prof
        persistProfile()
    }

    // MARK: - Picture Menu Preference

    var pictureMenuPreference: PictureMenuPreference {
        profile.pictureMenuPreference ?? PictureMenuPreference()
    }

    // MARK: - Caregiver Programmed Orders

    var pendingCaregiverPickupOrder: CaregiverProgrammedOrder? {
        profile.caregiverProgrammedOrders.first { $0.isReadyForPickup && !$0.alertSent }
    }

    func saveCaregiverOrder(_ order: CaregiverProgrammedOrder) {
        profile.caregiverProgrammedOrders.append(order)
        persistProfile()
    }

    func markCaregiverOrderAlertSent(id: UUID) {
        if let idx = profile.caregiverProgrammedOrders.firstIndex(where: { $0.id == id }) {
            profile.caregiverProgrammedOrders[idx].alertSent = true
        }
        persistProfile()
    }

    // MARK: - Private persistence helper
    // NOTE: Renamed from save() to persistProfile() to avoid
    // shadowing any existing save() method in UserSessionViewModel.
    private func persistProfile() {
        PersistenceManager.shared.saveProfile(profile)
    }
}
