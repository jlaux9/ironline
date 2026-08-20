-- Forward-only. Two unrelated pre-production fixes that share a phase.
--
-- PART A — 'in_progress' must not be an immortal duel state. (additive/safe)
--
-- 008's status check allows six states, and its cron sweep flips only
-- 'pending' and 'accepted' to 'expired'. Nothing currently writes
-- 'in_progress', but the schema permits it, so a row that reached it would
-- never expire: the sweep would skip it forever and, because expiry is now
-- part of the authoritative transition conditions in respond-duel and
-- resolve_duel, it could also never be answered or resolved. A duel stuck
-- open permanently, occupying the active-matchup index and blocking rematches.
--
-- Decision, made explicitly rather than left implicit: 'in_progress' stays in
-- the model as a reserved active state, and everything that treats a duel as
-- active now covers it consistently — 017's uniqueness index and this sweep.
-- If it is later confirmed dead, removing it from the check constraint is a
-- separate deliberate migration, not something to leave half-handled.
--
-- 008 is applied history and is not edited. cron.schedule on an existing job
-- name replaces its definition in place.
select cron.schedule(
  'expire-duels',
  '*/15 * * * *',
  $$ update public.duels set status = 'expired'
     where status in ('pending', 'accepted', 'in_progress') and expires_at < now(); $$
);

-- PART B — ghost_records is derived state and must not be client-writable.
--   BREAKING: apply only AFTER the updated save-set is deployed.
--
-- 010 granted authenticated users direct INSERT and UPDATE on their own ghost
-- records. Ghosts are supposed to be derived by save-set from an authoritative
-- set insert, but those policies let a caller bypass save-set entirely and
-- invent a ghost, mark one beaten, rewrite beaten_by_set_id, or change a
-- recorded ghost's weight and reps. "Beat your ghost" is a competitive claim,
-- so it should be derived, never asserted by the client.
--
-- save-set now performs ghost bookkeeping with the service role, after
-- authenticating the caller, verifying the session belongs to them, and
-- writing the set itself.
--
-- SELECT is deliberately untouched: users still read their own ghosts under
-- their own JWT, and that scoping is what keeps one user out of another's.
--
-- Same honesty caveat as 020: this centralises ghost derivation behind
-- save-set. It does not prove the rep payload save-set was handed came from
-- the camera referee. It removes an unpoliced write path; it is not anti-cheat.
drop policy if exists "Users can insert their own ghost records" on public.ghost_records;
drop policy if exists "Users can update their own ghost records" on public.ghost_records;
