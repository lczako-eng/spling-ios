// ============================================================
// SPLING — FULL STACK v5
// AccessibilityPathways_Part2.swift
// Contains:
// • PictureMenuView (Visual Picture Menu pathway)
// • PictureMenuViewModel
// • CaregiverProgramView (Caregiver Pre-Programming pathway)
// • CaregiverPickupAlertView
// • CaregiverProgramViewModel
// ADD this file to your Xcode target.
// ============================================================
import SwiftUI

// ─────────────────────────────────────────────────────────────
// MARK: - Picture Menu ViewModel
// ─────────────────────────────────────────────────────────────

@MainActor
class PictureMenuViewModel: ObservableObject {
    @Published var pictureCart: [PictureCartEntry] = []
    @Published var lastAddedItem: MenuItem?
    @Published var showConfirmationFlash: Bool = false

    var totalCents: Int { pictureCart.reduce(0) { $0 + $1.subtotalCents } }
    var formattedTotal: String { String(format: "$%.2f", Double(totalCents) / 100.0) }
    var isEmpty: Bool { pictureCart.isEmpty }
    var itemCount: Int { pictureCart.reduce(0) { $0 + $1.quantity } }

    func addItem(_ item: MenuItem) {
        if let idx = pictureCart.firstIndex(where: { $0.menuItem.id == item.id }) {
            pictureCart[idx].quantity += 1
        } else {
            pictureCart.append(PictureCartEntry(menuItem: item, quantity: 1, confirmedByPhoto: true))
        }
        lastAddedItem = item
        showConfirmationFlash = true
        HapticManager.shared.impact(.medium)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.showConfirmationFlash = false
        }
    }

    func removeItem(_ item: MenuItem) {
        pictureCart.removeAll { $0.menuItem.id == item.id }
    }

    /// Transfers picture-cart items to the shared CartViewModel for checkout
    func transferToCart(_ cart: CartViewModel) {
        for entry in pictureCart {
            for _ in 0..<entry.quantity {
                cart.add(entry.menuItem)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Picture Menu Tile View
// ─────────────────────────────────────────────────────────────

struct PictureMenuTile: View {
    let item: MenuItem
    let tileSize: PictureMenuTileSize
    let isInCart: Bool
    let onTap: () -> Void

    @EnvironmentObject var accessibility: AccessibilityViewModel

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                // Photo background (placeholder — replace with AsyncImage)
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.15), Color.purple.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(minHeight: tileSize.minHeight)
                    .overlay {
                        VStack {
                            Image(systemName: "fork.knife.circle.fill")
                                .font(.system(size: tileSize == .xl ? 70 : tileSize == .large ? 54 : 38))
                                .foregroundStyle(.blue.opacity(0.5))
                            Spacer()
                        }
                        .padding(.top, 16)
                    }

                // Label overlay
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: accessibility.dynamicFontSize, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if item.priceCents > 0 {
                        Text(item.formattedPrice)
                            .font(.system(size: accessibility.dynamicFontSize - 2, weight: .semibold))
                            .foregroundStyle(.blue)
                    }

                    if !item.allergens.isEmpty {
                        Text(item.allergens.joined(separator: ", "))
                            .font(.system(size: accessibility.dynamicFontSize - 5))
                            .foregroundStyle(.orange.opacity(0.9))
                    }
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(8)

                // In-cart badge
                if isInCart {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 24))
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(item.name). \(item.priceCents > 0 ? item.formattedPrice : "Price unavailable"). " +
            (isInCart ? "Already in order." : "Tap to add to order.")
        )
        .accessibilityHint(isInCart ? "" : "Tap to add to order. Haptic buzz will confirm.")
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Picture Menu View
// ─────────────────────────────────────────────────────────────

struct PictureMenuView: View {
    let vendor: Vendor
    let preference: PictureMenuPreference
    let onComplete: (PictureMenuViewModel) -> Void
    let onDismiss: () -> Void

    @StateObject private var vm = PictureMenuViewModel()
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @State private var selectedTileSize: PictureMenuTileSize
    @State private var selectedCategory: MenuCategory?

    init(vendor: Vendor, preference: PictureMenuPreference,
         onComplete: @escaping (PictureMenuViewModel) -> Void,
         onDismiss: @escaping () -> Void) {
        self.vendor = vendor
        self.preference = preference
        self.onComplete = onComplete
        self.onDismiss = onDismiss
        _selectedTileSize = State(initialValue: preference.tileSize)
        _selectedCategory = State(initialValue: vendor.menuCategories.first)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Category tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(vendor.menuCategories) { cat in
                            Button(cat.name) {
                                selectedCategory = cat
                                HapticManager.shared.selection()
                            }
                            .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                selectedCategory?.id == cat.id ? Color.blue : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                            .foregroundStyle(selectedCategory?.id == cat.id ? .white : .primary)
                            .accessibilityLabel(cat.name)
                            .accessibilityAddTraits(selectedCategory?.id == cat.id ? [.isSelected] : [])
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                // Tile size selector
                HStack {
                    Text("Tile Size:")
                        .font(.system(size: accessibility.dynamicFontSize - 3))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $selectedTileSize) {
                        ForEach(PictureMenuTileSize.allCases, id: \.self) { size in
                            Text(size.rawValue).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Tile size selector")
                }
                .padding(.horizontal)

                Divider()

                // Item grid
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: selectedTileSize.columns),
                        spacing: 10
                    ) {
                        ForEach(selectedCategory?.items ?? []) { item in
                            PictureMenuTile(
                                item: item,
                                tileSize: selectedTileSize,
                                isInCart: vm.pictureCart.contains(where: { $0.menuItem.id == item.id })
                            ) {
                                vm.addItem(item)
                                accessibility.announceForVoiceOver("\(item.name) added to your order.")
                            }
                        }
                    }
                    .padding()
                }

                // Haptic confirmation flash
                if vm.showConfirmationFlash, let item = vm.lastAddedItem {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title2)
                        Text("\(item.name) added!")
                            .font(.system(size: accessibility.dynamicFontSize - 1, weight: .semibold))
                        Spacer()
                    }
                    .padding()
                    .background(Color.green.opacity(0.12))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(duration: 0.3), value: vm.showConfirmationFlash)
                }

                // Photo cart strip
                if !vm.isEmpty {
                    photoCartStrip
                }
            }
            .navigationTitle("Picture Menu — \(vendor.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !vm.isEmpty {
                        Button {
                            onComplete(vm)
                        } label: {
                            Label("Checkout (\(vm.itemCount))", systemImage: "bag.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel("Go to checkout with \(vm.itemCount) items, total \(vm.formattedTotal)")
                    }
                }
            }
        }
    }

    // MARK: - Photo Cart Strip

    private var photoCartStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your Order")
                .font(.system(size: accessibility.dynamicFontSize - 2, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(vm.pictureCart) { entry in
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.blue.opacity(0.1))
                                    .frame(width: 64, height: 64)
                                Image(systemName: "fork.knife")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.blue.opacity(0.5))
                                // Quantity badge
                                Text("\(entry.quantity)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(Color.blue, in: Circle())
                                    .offset(x: 22, y: -22)
                            }
                            Text(entry.menuItem.name)
                                .font(.system(size: accessibility.dynamicFontSize - 5))
                                .lineLimit(1)
                                .frame(width: 64)
                        }
                        .onTapGesture {
                            vm.removeItem(entry.menuItem)
                            HapticManager.shared.impact(.light)
                        }
                        .accessibilityLabel("\(entry.menuItem.name), quantity \(entry.quantity). Tap to remove.")
                    }
                }
                .padding(.horizontal)
            }

            Text("Total: \(vm.formattedTotal)")
                .font(.system(size: accessibility.dynamicFontSize - 1, weight: .bold))
                .foregroundStyle(.blue)
                .padding(.horizontal)
                .padding(.bottom, 4)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Caregiver Program ViewModel
// ─────────────────────────────────────────────────────────────

@MainActor
class CaregiverProgramViewModel: ObservableObject {
    @Published var vendorName: String = ""
    @Published var vendorURL: String = ""
    @Published var userDisplayName: String = ""
    @Published var caregiverName: String = ""
    @Published var dietaryNotes: String = ""
    @Published var scheduleType: CaregiverProgrammedOrder.ScheduleType = .onDemand
    @Published var scheduledDate: Date = Date().addingTimeInterval(3600)
    @Published var recurringPattern: String = ""
    @Published var phraseEntries: [CaregiverVoicePhrase] = []
    @Published var newPhraseText: String = ""
    @Published var newPhraseItemName: String = ""
    @Published var newPhraseItemID: String = ""
    @Published var isSaved: Bool = false
    @Published var availableMenuItems: [MenuItem] = []
    @Published var isLoadingMenu: Bool = false
    @Published var menuLoadError: String?

    var canSave: Bool {
        !vendorName.isEmpty && !userDisplayName.isEmpty && !caregiverName.isEmpty
    }

    func loadMenuForVoiceTraining() async {
        guard !vendorURL.isEmpty else { return }
        isLoadingMenu = true
        menuLoadError = nil
        do {
            let cache = try await AIMenuService.shared.fetchMenu(from: vendorURL, vendorName: vendorName)
            availableMenuItems = cache.categories.flatMap(\.items)
        } catch {
            menuLoadError = error.localizedDescription
        }
        isLoadingMenu = false
    }

    func addVoicePhrase() {
        guard !newPhraseText.isEmpty, !newPhraseItemID.isEmpty else { return }
        let phrase = CaregiverVoicePhrase(
            phrase: newPhraseText,
            menuItemID: newPhraseItemID,
            menuItemName: newPhraseItemName,
            addedBy: caregiverName
        )
        phraseEntries.append(phrase)
        newPhraseText = ""
        newPhraseItemName = ""
        newPhraseItemID = ""
        HapticManager.shared.impact(.light)
    }

    func buildOrder() -> CaregiverProgrammedOrder {
        CaregiverProgrammedOrder(
            caregiverName: caregiverName,
            userDisplayName: userDisplayName,
            vendorID: vendorURL.isEmpty ? UUID().uuidString : String(vendorURL.prefix(40)),
            vendorName: vendorName,
            vendorURL: vendorURL.isEmpty ? nil : vendorURL,
            items: [],
            dietaryRestrictions: dietaryNotes
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            portionNotes: "",
            scheduleType: scheduleType,
            scheduledDate: scheduleType == .scheduled ? scheduledDate : nil,
            recurringPattern: scheduleType == .recurring ? recurringPattern : nil
        )
    }

    func buildVoicePhraseMap() -> [String: String] {
        Dictionary(uniqueKeysWithValues: phraseEntries.map { ($0.phrase, $0.menuItemID) })
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Caregiver Program View (remote order setup)
// ─────────────────────────────────────────────────────────────

struct CaregiverProgramView: View {
    @StateObject private var vm = CaregiverProgramViewModel()
    @EnvironmentObject var session: UserSessionViewModel
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Who & Where
                Section {
                    TextField("Your name (caregiver)", text: $vm.caregiverName)
                        .font(.system(size: accessibility.dynamicFontSize))
                        .accessibilityLabel("Caregiver name")

                    TextField("Name of person you care for", text: $vm.userDisplayName)
                        .font(.system(size: accessibility.dynamicFontSize))
                        .accessibilityLabel("User's name")

                    TextField("Vendor / restaurant name", text: $vm.vendorName)
                        .font(.system(size: accessibility.dynamicFontSize))
                        .accessibilityLabel("Vendor name")

                    TextField("Vendor website (optional, for AI menu)", text: $vm.vendorURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(size: accessibility.dynamicFontSize))
                        .accessibilityLabel("Vendor website URL for AI menu loading")
                } header: {
                    Text("Who & Where").font(.system(size: accessibility.dynamicFontSize - 2))
                }

                // MARK: Dietary Restrictions
                Section {
                    TextField("e.g. no nuts, soft foods only, no dairy", text: $vm.dietaryNotes, axis: .vertical)
                        .font(.system(size: accessibility.dynamicFontSize))
                        .lineLimit(2...4)
                        .accessibilityLabel("Dietary restrictions, comma separated")
                } header: {
                    Text("Dietary Restrictions").font(.system(size: accessibility.dynamicFontSize - 2))
                } footer: {
                    Text("Separate restrictions with commas")
                        .font(.system(size: accessibility.dynamicFontSize - 4))
                }

                // MARK: Schedule
                Section {
                    Picker("Order Type", selection: $vm.scheduleType) {
                        Text("On Demand").tag(CaregiverProgrammedOrder.ScheduleType.onDemand)
                        Text("Scheduled").tag(CaregiverProgrammedOrder.ScheduleType.scheduled)
                        Text("Recurring").tag(CaregiverProgrammedOrder.ScheduleType.recurring)
                    }
                    .font(.system(size: accessibility.dynamicFontSize))

                    if vm.scheduleType == .scheduled {
                        DatePicker("Pickup Date & Time",
                                   selection: $vm.scheduledDate,
                                   displayedComponents: [.date, .hourAndMinute])
                            .font(.system(size: accessibility.dynamicFontSize))
                    }

                    if vm.scheduleType == .recurring {
                        TextField("e.g. every Tuesday lunch", text: $vm.recurringPattern)
                            .font(.system(size: accessibility.dynamicFontSize))
                            .accessibilityLabel("Recurring schedule pattern")
                    }
                } header: {
                    Text("Schedule").font(.system(size: accessibility.dynamicFontSize - 2))
                }

                // MARK: ML Voice Training
                Section {
                    if !vm.vendorURL.isEmpty {
                        if vm.isLoadingMenu {
                            HStack {
                                ProgressView()
                                Text("Loading menu for phrase setup…")
                                    .font(.system(size: accessibility.dynamicFontSize - 2))
                                    .foregroundStyle(.secondary)
                            }
                        } else if let error = vm.menuLoadError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: accessibility.dynamicFontSize - 3))
                        } else if !vm.availableMenuItems.isEmpty {
                            voicePhraseSection
                        } else {
                            Button("Load Menu for Voice Phrase Setup") {
                                Task { await vm.loadMenuForVoiceTraining() }
                            }
                            .font(.system(size: accessibility.dynamicFontSize - 1))
                        }
                    } else {
                        Text("Enter vendor website above to set up voice phrases for the ML model.")
                            .font(.system(size: accessibility.dynamicFontSize - 3))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Label("Train ML Voice Model", systemImage: "brain.head.profile")
                        .font(.system(size: accessibility.dynamicFontSize - 2))
                } footer: {
                    Text("Phrases entered here help the AI recognise how this person speaks.")
                        .font(.system(size: accessibility.dynamicFontSize - 4))
                }

                // MARK: Save
                Section {
                    Button("Save Order for User") {
                        guard vm.canSave else { return }
                        let order = vm.buildOrder()
                        session.saveCaregiverOrder(order)
                        let phrases = vm.buildVoicePhraseMap()
                        if !phrases.isEmpty {
                            session.mergeVoicePhrases(phrases)
                        }
                        HapticManager.shared.notification(.success)
                        vm.isSaved = true
                    }
                    .disabled(!vm.canSave)
                    .font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
                    .accessibilityLabel(vm.canSave
                        ? "Save caregiver order for \(vm.userDisplayName)"
                        : "Fill in all required fields to save")
                }

                if vm.isSaved {
                    Section {
                        Label("Order saved! \(vm.userDisplayName) will get a notification when it's ready.",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: accessibility.dynamicFontSize - 1))
                    }
                }
            }
            .navigationTitle("Caregiver Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Voice Phrase Sub-Section

    private var voicePhraseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !vm.phraseEntries.isEmpty {
                ForEach(vm.phraseEntries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\"\(entry.phrase)\"")
                                .font(.system(size: accessibility.dynamicFontSize - 2, weight: .medium))
                            Text("→ \(entry.menuItemName)")
                                .font(.system(size: accessibility.dynamicFontSize - 4))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.purple)
                            .font(.caption)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Add a phrase the user says:")
                    .font(.system(size: accessibility.dynamicFontSize - 3))
                    .foregroundStyle(.secondary)

                TextField("e.g. 'the usual' or 'my sandwich'", text: $vm.newPhraseText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: accessibility.dynamicFontSize - 1))

                Picker("Maps to menu item:", selection: $vm.newPhraseItemID) {
                    Text("Select item").tag("")
                    ForEach(vm.availableMenuItems) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                .pickerStyle(.menu)
                .font(.system(size: accessibility.dynamicFontSize - 1))
                .onChange(of: vm.newPhraseItemID) { _, newID in
                    vm.newPhraseItemName = vm.availableMenuItems.first(where: { $0.id == newID })?.name ?? ""
                }

                Button("Add Phrase to ML Model") {
                    vm.addVoicePhrase()
                    accessibility.announceForVoiceOver("Voice phrase added to model.")
                }
                .disabled(vm.newPhraseText.isEmpty || vm.newPhraseItemID.isEmpty)
                .buttonStyle(.bordered)
                .tint(.purple)
                .font(.system(size: accessibility.dynamicFontSize - 2))
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Caregiver Pickup Alert View
// ─────────────────────────────────────────────────────────────

/// Shown when the app receives notification that a caregiver order is ready.
/// One giant button — designed for scooter users and people with motor difficulties.
struct CaregiverPickupAlertView: View {
    let programmedOrder: CaregiverProgrammedOrder
    let onGoPickUp: () -> Void
    let onDismiss: () -> Void

    @EnvironmentObject var accessibility: AccessibilityViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "bag.fill.badge.plus")
                .font(.system(size: 72))
                .foregroundStyle(.green)

            VStack(spacing: 10) {
                Text("Your order is ready!")
                    .font(.system(size: accessibility.dynamicFontSize + 10, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("\(programmedOrder.vendorName)")
                    .font(.system(size: accessibility.dynamicFontSize + 4))
                    .foregroundStyle(.secondary)

                if let pattern = programmedOrder.recurringPattern {
                    Text("Recurring: \(pattern)")
                        .font(.system(size: accessibility.dynamicFontSize - 2))
                        .foregroundStyle(.tertiary)
                }
            }

            // THE one giant button
            Button {
                HapticManager.shared.notification(.success)
                onGoPickUp()
            } label: {
                Text("Go Pick Up Now")
                    .font(.system(size: accessibility.dynamicFontSize + 6, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.extraLarge)
            .padding(.horizontal, 24)
            .accessibilityLabel("Go pick up your order at \(programmedOrder.vendorName) now")
            .accessibilityHint("Opens the ready-to-send order. Tap NFC at the terminal to complete.")

            Button("Dismiss") { onDismiss() }
                .foregroundStyle(.secondary)
                .font(.system(size: accessibility.dynamicFontSize - 1))
                .accessibilityLabel("Dismiss this notification")

            Spacer()
        }
        .padding()
        .onAppear {
            HapticManager.shared.notification(.success)
            accessibility.announceForVoiceOver(
                "Your order at \(programmedOrder.vendorName) is ready to pick up. Tap the green button to go now."
            )
        }
    }
}
