//
//  spLingTests.swift
//  spLingTests
//
//  Created by Laszlo Czako on 2026-02-21.
//

import Testing
import Foundation
@testable import spLing

// ============================================================================
// The accuracy ledger's input.
//
// These guard one property: a correction that reaches the ledger can be
// attributed. A row saying "something was wrong" and nothing else cannot be
// tied to a merchant, a location, an item or a modifier — it is a complaint,
// not a measurement, and the third pillar is measurement.
// ============================================================================

struct CorrectionTests {

    private func menuItem(_ id: String, _ name: String, _ cents: Int) -> MenuItem {
        MenuItem(
            id: id, name: name, description: "", priceCents: cents,
            imageURL: nil, customizations: [], allergens: [], calories: nil
        )
    }

    private func order() -> Order {
        Order(
            vendorID: "v1",
            vendorName: "Fern Café",
            items: [
                OrderItem(menuItem: menuItem("m1", "Large Latte", 550), quantity: 1),
                OrderItem(menuItem: menuItem("m2", "Cheeseburger", 899), quantity: 2),
            ]
        )
    }

    // ---- the contract shared with the connector ----------------------------

    @Test("kinds match the connector's submit_correction enum exactly")
    func kindsMatchServer() {
        // Mirrors supabase/functions/spling-mcp/index.ts. Both rails write into
        // one ledger; a value that exists on only one side produces rows the
        // other cannot read. protocol_test.ts fails too if these drift.
        let server = ["missing_item", "wrong_item", "wrong_modifier", "wrong_quantity", "quality", "other"]
        #expect(CorrectionKind.allCases.map(\.rawValue).sorted() == server.sorted())
    }

    @Test("a correction serialises to the field names the ledger expects")
    func wireFormat() throws {
        let c = Correction(
            orderID: UUID(), vendorID: "v1", kind: .wrongModifier,
            itemName: "Large Latte", received: "whole milk", note: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try JSONSerialization.jsonObject(with: encoder.encode(c)) as? [String: Any]

        #expect(json?["order_id"] != nil)
        #expect(json?["item_name"] as? String == "Large Latte")
        #expect(json?["kind"] as? String == "wrong_modifier")
        #expect(json?["received"] as? String == "whole milk")
        // Absent, not empty — an empty string reads as an answer.
        #expect(json?["note"] == nil)
    }

    // ---- the refusals that make the ledger worth having --------------------

    @Test("a correction with no description of what arrived is refused")
    func requiresReceived() {
        let c = Correction(orderID: order().id, vendorID: "v1", kind: .wrongItem, itemName: "Large Latte")
        #expect(throws: CorrectionError.self) {
            try CorrectionService.shared.validate(c)
        }
    }

    @Test("whitespace is not an answer")
    func whitespaceIsAbsence() {
        let c = Correction(
            orderID: order().id, vendorID: "v1", kind: .wrongItem,
            itemName: "Large Latte", received: "   \n  "
        )
        #expect(c.received == nil, "whitespace must normalise to absent before it can be stored")
        #expect(throws: CorrectionError.self) {
            try CorrectionService.shared.validate(c)
        }
    }

    @Test("a correction that names no item is refused, except for 'other'")
    func requiresItem() {
        #expect(throws: CorrectionError.self) {
            try CorrectionService.shared.validate(
                Correction(orderID: order().id, vendorID: "v1", kind: .missingItem)
            )
        }
        // 'other' may not belong to one line, but then it has to say something.
        #expect(throws: CorrectionError.self) {
            try CorrectionService.shared.validate(
                Correction(orderID: order().id, vendorID: "v1", kind: .other)
            )
        }
        #expect(throws: Never.self) {
            try CorrectionService.shared.validate(
                Correction(orderID: order().id, vendorID: "v1", kind: .other, note: "Counter was closed.")
            )
        }
    }

    @Test("a missing item needs no 'instead' — nothing arrived")
    func missingItemNeedsNoReceived() {
        #expect(CorrectionKind.missingItem.requiresReceived == false)
        #expect(throws: Never.self) {
            try CorrectionService.shared.validate(
                Correction(orderID: order().id, vendorID: "v1", kind: .missingItem, itemName: "Cheeseburger")
            )
        }
    }

    @Test("every kind asks a question specific to it")
    func promptsAreDistinct() {
        let prompts = CorrectionKind.allCases.map(\.receivedPrompt)
        #expect(Set(prompts).count == prompts.count, "a shared prompt means a kind that teaches nothing extra")
        for kind in CorrectionKind.allCases {
            #expect(!kind.label.isEmpty)
            #expect(kind.receivedPrompt.hasSuffix("?"))
        }
    }

    // ---- the form ----------------------------------------------------------

    @Test("items are offered from the order, deduplicated, so names cannot drift")
    @MainActor
    func itemChoicesComeFromTheOrder() {
        let o = order()
        let vm = CorrectionViewModel()
        #expect(vm.itemChoices(for: o) == ["Large Latte", "Cheeseburger"])
    }

    @Test("the submit button is blocked for exactly the reasons the service refuses")
    @MainActor
    func buttonMirrorsValidation() {
        let o = order()
        let vm = CorrectionViewModel()
        vm.kind = .wrongModifier

        #expect(vm.canSubmit(for: o) == false)
        #expect(vm.blocker(for: o) != nil, "a disabled button must say what is missing")

        vm.itemName = "Large Latte"
        #expect(vm.canSubmit(for: o) == false, "still no description of what arrived")

        vm.received = "whole milk"
        #expect(vm.canSubmit(for: o) == true)
        #expect(vm.blocker(for: o) == nil)
    }
}
