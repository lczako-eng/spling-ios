# Spling

Your AI assistant is your mouth. Order in your language, without speaking, anywhere.

An MCP server that lets Claude and ChatGPT place validated, structured food orders on a
user's behalf via Square — carrying the user's language and communication profile so the
spoken channel is never required at the point of sale.

## Quick start
1. Read CLAUDE.md (build rules) and docs/BUILD_PLAN.md (the week, day by day)
2. Square Developer app → sandbox token
3. New Supabase project → `supabase link` → `supabase db push`
4. `supabase secrets set SQUARE_ACCESS_TOKEN=... SQUARE_ENV=sandbox SPLING_BEARER=$(openssl rand -hex 32)`
5. `supabase functions deploy spling-mcp --no-verify-jwt`
6. Add to Claude as a custom connector (function URL + bearer)

## Repo map
- `CLAUDE.md` — rules Claude Code follows
- `supabase/functions/spling-mcp/index.ts` — the MCP server (Phase 1 live, 2–5 stubbed)
- `supabase/migrations/001_init.sql` — full schema, all phases, RLS everywhere
- `docs/BUILD_PLAN.md` — 7 days, 7 checkpoints
- `docs/WEBSITE_BRIEF.md` — spling.org redesign direction

© 2026 R-evolv Inc.
