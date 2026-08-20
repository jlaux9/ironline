# API Contract — Direct Client vs. Edge Functions

Per framework spec §9. This is the line both of you build against.

## Direct Supabase client (`supabase-swift`)

Reads and simple single-table writes. No business logic.

| Operation | Table |
|---|---|
| Sign up / sign in / sign out | `auth` |
| Read / update own profile | `users` |
| List active exercises | `exercises` |
| Create / complete a workout session | `workout_sessions` |
| Read own set/session history (raw) | `workout_sessions`, `sets` |
| Read own LINE history (for the history chart) | `the_line` |
| Read friends / crew membership | `friendships`, `crews`, `crew_members` |
| Create a crew (creator auto-added as leader) | `crews` |
| Leave a crew / disband a crew you created | `crew_members`, `crews` |
| Create / view your own invite codes | `invite_codes` |
| Read your active duels / duel history (read-only — see below) | `duels` |
| Read your own ranking | `rankings` |
| Read your own ghost record history | `ghost_records` |
| Mark a trash-talk message seen | `trash_talk_log` |

RLS on each table enforces `auth.uid()` scoping — the client never needs to filter by user id manually, but should anyway for clarity.

**Authority rule:** clients never write `the_line`, duel outcomes, rankings/ELO, or other competitive state directly. Those values must be produced by trusted server logic from verified inputs.

## Edge Functions (`supabase/functions/`)

Anything with cross-table logic, external calls, or rules that shouldn't ship in the app binary.

| Function | Triggers | Does |
|---|---|---|
| `save-set` | client submits a completed verified set | inserts into `sets`, checks prior sets for that exercise, flags `is_pr`, records/updates `ghost_records` |
| `get-history` | client requests set history for an exercise | returns the caller's sets for that `exercise_id`, most recent first |
| `calculate-line` | after a session completes for an exercise | Epley e1RM, recency weighting, writes a new authoritative `the_line` version via service role (or baseline countdown if <3 sessions) |
| `get-line` | client wants the active LINE for an exercise | returns the highest-version `the_line` row, or `{ baseline: true, sessions_remaining }` if none exists |
| `line-score` | client wants a set scored against the LINE | `(actual_e1RM - predicted_e1RM) / predicted_e1RM x 100` for a given `set_id` |
| `friend-request` | send/accept/decline a friend request | `action: send/accept/decline`; auto-accepts a reciprocal pending request instead of creating a duplicate |
| `redeem-invite` | client redeems a code | looks up a `friend` or `crew` invite code, creates the friendship or crew membership |
| `friend-activity` | client views a friend's activity | verifies the friendship, then returns their recent completed sessions + PRs |
| `crew-leaderboard` | client views a crew's leaderboard | verifies membership, ranks the roster by each member's most recent `line_score` |
| `create-duel` | challenger issues a duel | requires an **accepted friendship**; references a set they already saved that is theirs, matches the exercise, and is **under 48h old**; computes `challenger_line_score`, creates the duel (`pending`, expires in 48h). One live duel per (challenger, opponent, exercise); a set can back only one duel |
| `respond-duel` | opponent responds | `action: accept/decline`; declining is terminal, no ELO change. Service-role write, authorized to this duel's opponent out of `pending` only |
| `resolve-duel` | opponent submits their set | set must be theirs, match the exercise, and have been **performed after the duel was created**; computes `opponent_line_score`, picks the winner (or draw), then calls `resolve_duel` which transitions the duel and updates both ELOs in one transaction. Returns 409 if already resolved |
| `get-ghost` | client requests ghost for an exercise | returns the caller's best *unbeaten* set to race, from `ghost_records` |
| `generate-trash-talk` | during active duel rest periods | calls a self-hosted LLM with duel context, writes `trash_talk_log`; skips quietly if unreachable |

Duel expiry (48h) runs as a `pg_cron` job directly against the `duels` table every 15 minutes — no Edge Function needed for a plain status flip.

Each function expects the caller's Supabase JWT in the `Authorization` header and derives `auth.uid()` server-side — never trust a user id passed in the request body.

### Service role usage

Most functions use the anon key + forwarded user JWT, so RLS applies exactly as it would for a direct client call. `redeem-invite`, `friend-activity`, `crew-leaderboard`, `resolve-duel`, and `generate-trash-talk` are the exception — they need to read or write rows belonging to a user other than the caller (a code's creator, a friend's sessions, a crew's other members, the *other* duel participant's ranking, a duel's trash-talk log). These use the service role key internally, but each one manually verifies the relationship (friendship accepted, crew membership, duel participation) *before* touching any other user's data — the visibility rule lives in the function, not in relaxed RLS.

`calculate-line` uses the service role for a different reason: not cross-user access, but *write authority*. It reads the caller's own sets under RLS with the user-scoped client, then writes the resulting `the_line` row with the service role, because clients are not permitted to author competitive state at all (see "Authority rule" above). Functions that write authoritative competitive state may use the service-role client **only after authenticating the caller**, and the user id written to the database must come from that verified JWT — never from the request body. Service-role credentials never ship in the iOS app.

### Self-hosted LLM for trash talk

`generate-trash-talk` calls Ollama's native `/api/chat` (not the OpenAI-compatible path — only the native endpoint supports `"think": false`, which is required for this model to produce a timely answer instead of reasoning indefinitely). Configured via Supabase secrets: `LLM_API_BASE_URL`, `LLM_MODEL`, `LLM_API_KEY`. Currently pointed at `huihui_ai/qwen3.5-abliterated:9b` running locally via Ollama, reached through an authenticated proxy (`ops/trash-talk-proxy/`) over a Tailscale Funnel — full setup and rationale in that directory's README. A persona-lock system prompt keeps tone consistent (without it, the model tends to console the losing side rather than mock them). Trash talk is cosmetic — if the endpoint is down or unconfigured, the function returns `{ skipped: true }` instead of erroring; nothing duel-related depends on it.

### Competitive-state write authority (audited post-reconciliation)

`duels` has **no client UPDATE policy**. It was removed in `015` after the audit found the original opponent policy (`for update using (auth.uid() = opponent_id)`, no `WITH CHECK`) let an opponent PATCH `winner_id` onto themselves through PostgREST. A column blacklist in RLS was rejected as the fix — every future column would default to writable. Accept/decline and resolution both run server-side in `respond-duel` and `resolve-duel`, which authorize the caller and then write with the service role.

`rankings` likewise has no client write policy: ELO moves only inside `public.resolve_duel`, which is `SECURITY DEFINER` with EXECUTE revoked from `anon` and `authenticated`. A duel transitions `accepted → completed` exactly once — the status is reasserted in the `UPDATE ... WHERE`, and a retry gets 409 with no ELO applied.

`sets` likewise has no client INSERT or UPDATE policy after `020` — every set write goes through `save-set`, which verifies authentication and session ownership before writing with the service role.

**Be precise about what that last one means.** It closes direct PostgREST mutation of `sets` and gives set writes a single auditable entry point. It does **not** verify that the reported reps, weight, or ROM came from the camera referee — `save-set` accepts those fields from its caller. And it does not require a tampered app to abuse: `save-set` is an authenticated public Edge Function, so any user who can sign in can call it directly with a fabricated payload. This is authority hygiene, not anti-cheat. Real attestation would need App Attest / device attestation or server-verifiable referee evidence, both outside V1 scope. **Nothing here is "server-verified reps."**

Backend invariants for all of the above are enforced in CI by `supabase/checks/authority-invariants.mjs`. They are static shape checks, not integration tests; concurrency behavior still needs verification against a real database.

## Security model (audited Phase 5)

- **Default**: every table has RLS enabled, self-scoped to `auth.uid()`. `exercises` is the one intentional exception — reference data, readable by any authenticated user.
- **Cross-user reads/writes** (a friend's activity, a crew's roster, the other side of a duel's ELO) go through Edge Functions using the service role key, each gated by an explicit relationship check *before* touching the other user's data — see "Service role usage" above.
- **RLS self-recursion**: policies that need to check "am I a member of X" against the same table they're protecting (`crew_members`) use a `SECURITY DEFINER` helper function (`is_crew_member()`) with a pinned `search_path`, rather than a same-table subquery directly in the policy — avoids infinite recursion and search_path hijacking.
- **User-supplied IDs in hand-built filters**: any function that constructs a raw PostgREST `.or()` filter string must validate the ID is a well-formed UUID first if it comes from the request (not the JWT or a trusted DB row) — see `friend-activity` for the pattern. Don't interpolate unvalidated request input into a filter string.

## Swift invocation convention

- POST/body functions use `APIService.invoke(_:body:)`.
- GET/query functions such as `get-line` use `APIService.invokeGET(_:query:)`.

## Adding a new Edge Function

1. `supabase functions new <name>`
2. Import shared CORS/auth helpers from `supabase/functions/_shared/`
3. Test locally: `supabase functions serve <name>`
4. Deploy: `supabase functions deploy <name>`
