// ============================================================================
// The directory provider — every business that is not a point of sale.
//
// A pharmacy counter, a hotel desk, a clinic, a government service window and a
// stadium accessibility office all have the same shape: they publish what they
// offer, and someone has to make themselves understood well enough to ask for
// one of those things. None of them have a Square catalog, and most of them
// will never have an API.
//
// So this provider reads a catalogue the business publishes into Spling itself
// (migration 003), and "submitting" means recording an exact, structured request
// with a reference the counter can look up. There is no payment leg: a
// prescription pickup and an accessible room request do not take money here,
// and pretending otherwise would put us in a rail we deliberately stay out of.
//
// This is also the proof that the abstraction in catalogue.ts is real rather
// than Square's shape wearing a different name — see compose_domains_test.ts.
// ============================================================================

import type {
  Catalogue, CatalogueKind, CatalogueProvider, Offering, SubmittedTransaction,
} from "./catalogue.ts";
import { nounFor, registerProvider } from "./catalogue.ts";

// deno-lint-ignore no-explicit-any
const env = (k: string): string => (globalThis as any).Deno?.env?.get(k) ?? "";
const SUPABASE_URL = env("SUPABASE_URL");
const SERVICE_KEY = env("SUPABASE_SERVICE_ROLE_KEY");

const TTL_MS = 15 * 60 * 1000;
const cache = new Map<string, { at: number; catalogue: Catalogue }>();

export function clearDirectoryCache() { cache.clear(); }

async function pg(path: string): Promise<any> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
  });
  const text = await res.text();
  const body = text ? JSON.parse(text) : null;
  if (!res.ok) throw new Error(`directory ${path} ${res.status}: ${JSON.stringify(body)}`);
  return body;
}

/**
 * Rows out of `offerings` into the domain model. Pure, so the mapping is
 * testable without a database — the same discipline as buildMenu.
 */
export function buildDirectoryCatalogue(
  locationId: string,
  kind: CatalogueKind,
  rows: any[],
  currency = "CAD",
): Catalogue {
  const offerings: Offering[] = (rows ?? [])
    .filter((r) => r.active !== false)
    .map((r) => ({
      id: r.external_id ?? r.id,
      name: r.name ?? "",
      description: r.description ?? null,
      category: r.category ?? undefined,
      tags: Array.isArray(r.tags) ? r.tags.map((t: unknown) => String(t).toLowerCase()) : [],
      variants: (r.variants ?? []).map((v: any) => ({
        id: String(v.id),
        name: String(v.name ?? "Standard"),
        price_cents: Number(v.price_cents ?? 0),
        currency: String(v.currency ?? currency),
      })),
      option_groups: (r.option_groups ?? []).map((g: any) => ({
        id: String(g.id),
        name: String(g.name ?? "Options"),
        options: (g.options ?? []).map((o: any) => ({
          id: String(o.id),
          name: String(o.name ?? ""),
          price_cents: Number(o.price_cents ?? 0),
          group: String(g.name ?? ""),
        })),
      })),
    }))
    // A service with no requestable form cannot be asked for, so it is not
    // published — the same rule as an unpriced menu item. Free services carry a
    // zero-cost variant rather than none.
    .filter((o) => o.variants.length > 0);

  return {
    provider: "directory",
    location_id: locationId,
    kind,
    noun: nounFor(kind),
    fetched_at: new Date().toISOString(),
    offerings,
    currency,
  };
}

export const directoryProvider: CatalogueProvider = {
  name: "directory",

  async getCatalogue(locationId: string): Promise<Catalogue> {
    const hit = cache.get(locationId);
    if (hit && Date.now() - hit.at < TTL_MS) return hit.catalogue;

    const merchants = await pg(
      `merchants?square_location_id=eq.${encodeURIComponent(locationId)}&select=id,display_name,catalogue_kind,currency&limit=1`,
    );
    const merchant = merchants?.[0];
    if (!merchant) throw new Error(`No business is published under location "${locationId}".`);

    const rows = await pg(
      `offerings?merchant_id=eq.${merchant.id}&active=eq.true&select=*&order=name.asc`,
    );

    const catalogue = buildDirectoryCatalogue(
      locationId,
      (merchant.catalogue_kind ?? "services") as CatalogueKind,
      rows,
      merchant.currency ?? "CAD",
    );
    cache.set(locationId, { at: Date.now(), catalogue });
    return catalogue;
  },

  /**
   * There is no external system to call. The validated request IS the artifact:
   * it is recorded by the caller with a reference the counter can look up, and
   * handed to the person as something to show rather than something to say.
   */
  submit(input): Promise<SubmittedTransaction> {
    return Promise.resolve({
      reference: input.reference,
      external_id: null,
      total_cents: input.totalCents,
      currency: "CAD",
      checkout_url: null,     // no payment leg — see the header note
      status: "submitted",
    });
  },
};

registerProvider(directoryProvider);
