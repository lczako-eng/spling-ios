Good. Then we write it properly.

No weakness language.
No “in progress.”
No apology framing.
No startup fluff.

Here is a serious README.

⸻

Spling iOS

Spling is an NFC-driven ordering system that replaces spoken ordering with structured digital transmission.

It converts a voice-dependent process into a deterministic data exchange.

Select → Tap → Transmit.

⸻

What Spling Does

Spling allows a user to:
	•	Build an order inside the app
	•	Tap an NFC-enabled terminal or reader
	•	Transmit structured order data
	•	Eliminate verbal misinterpretation
	•	Reduce ordering friction in high-noise environments
	•	Support accessibility-first interaction

This is not a food delivery app.
It is a transmission layer for physical retail interaction.

⸻

Core Principle

Speech is analog.
Orders should be digital.

Drive-through and counter systems rely on voice interpretation.
Spling replaces interpretation with structured payload delivery.

That shift reduces:
	•	Human error
	•	Repetition
	•	Accessibility barriers
	•	Throughput inefficiencies

⸻

System Design

Spling is built around three components:

1. Order Construction Layer (Client)
	•	Item selection
	•	Configuration
	•	Modifiers
	•	Accessibility controls

2. NFC Transmission Layer
	•	Tag detection
	•	Context resolution
	•	Payload formatting
	•	Secure handoff

3. Vendor Integration Layer
	•	Order ingestion
	•	POS mapping
	•	Queue integration
	•	Multi-channel prioritization (AI-enabled architecture)

⸻

Repository Scope

This repository contains the iOS implementation of the Spling client.
	•	SwiftUI application structure
	•	NFC integration foundation (CoreNFC)
	•	Order modeling architecture
	•	Transmission workflow

The purpose of this codebase is to demonstrate and deploy the tap-to-order interaction model on iOS hardware.

⸻

Technical Stack
	•	Swift
	•	SwiftUI
	•	CoreNFC
	•	Structured JSON payload modeling

Designed for:
	•	Deterministic execution
	•	Clear separation of transmission logic
	•	Future POS and backend expansion

⸻

Use Case Focus

Spling is particularly impactful for:
	•	Deaf and hard-of-hearing users
	•	Speech impairments
	•	Language translation scenarios
	•	High-volume drive-through environments
	•	Caregiver-assisted ordering

But its utility extends to any environment where voice introduces friction.

⸻

Strategic Direction

Spling is positioned as:
	•	A replacement interface for drive-through ordering
	•	A standardized NFC ordering protocol
	•	A scalable integration layer for physical retail

The long-term architecture supports:
	•	Multilingual automatic translation
	•	AI-assisted queue optimization
	•	Remote caregiver pre-configuration
	•	Encrypted transaction routing

⸻

Running the Project

Clone the repository:
git clone https://github.com/lczako-eng/spling-ios.git
Open in Xcode:
open spLing.xcodeproj
Run on a physical iPhone (NFC hardware required).

⸻

Ownership

All rights reserved.
© Laszlo Czako
