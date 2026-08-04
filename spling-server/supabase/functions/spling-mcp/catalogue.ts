// ============================================================================
// The catalogue — what a business publishes that it offers.
//
// STRATEGY.md: the communication layer is the product and ordering is its first
// application. The composition engine was already structurally general — an
// offering with variants and options describes a coffee, a hotel room, a
// pharmacy service and a government appointment equally well — but it was named
// and typed as if food were the only case, which is how a "first application"
// quietly becomes the whole product.
//
// So the domain model is stated here, provider-agnostic, and each rail is an
// adapter into it:
//
//   Offering   a thing the business does   Latte      Accessible Room   Prescription pickup
//   Variant    the priced form of it       Large      King, 2 nights    Standard / Expedited
//   Option     a modifier on it            Oat milk   Late arrival      Text me when ready
//
// A provider's only job is to produce a Catalogue and accept a Transaction.
// compose.ts validates against the Catalogue and never learns which rail it
// came from — that is what keeps a pharmacy from needing a rewrite.
// ============================================================================

export type CatalogueKind =
  | "menu"          // food and drink
  | "services"      // pharmacy, government desk, help desk
  | "rooms"         // hotels, accessible accommodation
  | "seating"       // stadiums, venues, travel
  | "appointments"  // clinics, service desks
  | "goods";        // retail

export interface Option {
  id: string;
  name: string;
  price_cents: number;
  /** The group it belongs to, e.g. "Milk", "Accessibility", "Delivery speed". */
  group?: string;
}

export interface OptionGroup {
  id: string;
  name: string;
  options: Option[];
}

export interface Variant {
  id: string;
  name: string;
  price_cents: number;
  currency: string;
}

export interface Offering {
  id: string;
  name: string;
  description?: string | null;
  category?: string;
  variants: Variant[];
  option_groups: OptionGroup[];
  /**
   * Free-form tags the business publishes: allergens on a dish, "wheelchair
   * accessible" on a room, "photo ID required" on an appointment. Constraint
   * matching reads these — absence is never treated as safety.
   */
  tags?: string[];
}

export interface Catalogue {
  provider: string;
  location_id: string;
  kind: CatalogueKind;
  /** What this business calls a transaction: "order", "booking", "request". */
  noun: string;
  fetched_at: string;
  offerings: Offering[];
  currency?: string;
}

/** A validated transaction, ready for whichever rail produced the catalogue. */
export interface SubmittedTransaction {
  reference: string;
  external_id: string | null;
  total_cents: number;
  currency: string;
  /** Only rails that take money return one. A service desk does not. */
  checkout_url: string | null;
  status: string;
}

export interface CatalogueProvider {
  readonly name: string;
  /** The catalogue for one location, live. Never cached beyond its own TTL. */
  getCatalogue(locationId: string): Promise<Catalogue>;
  /** Push a validated transaction onto the rail. */
  submit(input: {
    locationId: string;
    lineItems: Array<{ catalog_object_id: string; qty: number; modifiers: Array<{ catalog_object_id: string }> }>;
    reference: string;
    idempotencyKey: string;
    totalCents: number;
  }): Promise<SubmittedTransaction>;
  /** Live status, where the rail can tell us. */
  status?(externalId: string): Promise<string>;
}

// ---------------------------------------------------------------------------
// registry
// ---------------------------------------------------------------------------

const providers = new Map<string, CatalogueProvider>();

export function registerProvider(p: CatalogueProvider): void {
  providers.set(p.name, p);
}

export function getProvider(name: string): CatalogueProvider {
  const p = providers.get(name);
  if (!p) {
    throw new Error(
      `No catalogue provider registered for "${name}". Known: ${[...providers.keys()].join(", ") || "none"}.`,
    );
  }
  return p;
}

export function knownProviders(): string[] {
  return [...providers.keys()];
}

/** Reset — tests only. */
export function clearProviders(): void {
  providers.clear();
}

// ---------------------------------------------------------------------------
// vocabulary
//
// A pharmacy does not have a "menu" and a hotel guest does not "order" a room.
// The wording a business would recognise is part of being understood, so it
// travels with the catalogue rather than being hard-coded in the copy.
// ---------------------------------------------------------------------------

export const NOUN_BY_KIND: Record<CatalogueKind, string> = {
  menu: "order",
  services: "request",
  rooms: "booking",
  seating: "booking",
  appointments: "appointment",
  goods: "order",
};

export function nounFor(kind: CatalogueKind): string {
  return NOUN_BY_KIND[kind] ?? "request";
}
