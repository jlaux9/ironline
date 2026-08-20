-- Forward-only. Makes the Data API privilege model explicit.
--
-- THE DEFECT THIS FIXES
-- A database built purely from this repository's migrations grants anon,
-- authenticated and service_role nothing at all. Verified in CI against a
-- fresh 001-021 chain: every table reported `auth=- svc=- anon=-`, and
-- grepping the chain confirms it -- there is not one table GRANT in
-- 001 through 021.
--
-- Production works today only because the project was provisioned through
-- Supabase, where ALTER DEFAULT PRIVILEGES on schema public granted those
-- rights ambiently as each table was created. Those grants live in the
-- project, not in this repo. So the migration history is not self-contained:
-- a fresh environment built from it alone -- staging, a restore, a new
-- project, a contributor's local stack -- comes up with a Data API that
-- rejects every request, and the failure looks like RLS ("permission denied
-- for table workout_sessions" on a plain SELECT) when it is really a missing
-- GRANT. Policies are never consulted if the role holds no privilege on the
-- table.
--
-- This migration is therefore additive against production, where the same
-- grants already exist ambiently, and corrective everywhere else.
--
-- THE MODEL
-- Grants mirror the surviving RLS policies. RLS decides *which rows*; the
-- grant decides *whether the verb is available at all*. Where a migration
-- deliberately revoked a policy, the matching grant is deliberately absent
-- (and revoked, in case an environment picked it up from default privileges):
--
--   013  the_line       INSERT removed -- LINE is server-authored
--   019  duels          INSERT + UPDATE removed -- outcomes are server-authored
--   020  sets           INSERT + UPDATE removed -- sets come from save-set
--   021  ghost_records  INSERT + UPDATE removed -- ghosts are derived
--
-- anon gets nothing. There is no unauthenticated product surface in V1, so
-- granting it would only widen the attack surface for no feature.

grant usage on schema public to authenticated, service_role;

-- ---------------------------------------------------------------- authenticated
-- users: read + create + edit own profile (001 policies; ProfileSetupView
-- upserts, IronLineApp reads).
grant select, insert, update on public.users to authenticated;

-- exercises: reference data, read-only (002 policy; WorkoutService looks up
-- the exercise id).
grant select on public.exercises to authenticated;

-- workout_sessions: WorkoutService creates one and marks it completed; save-set
-- reads it under the caller's JWT to prove session ownership (003 policies).
grant select, insert, update on public.workout_sessions to authenticated;

-- sets: read only. calculate-line, get-history, get-line, line-score,
-- create-duel and resolve-duel all read sets under the caller's JWT, and RLS
-- scopes that to the caller's own sessions. Writes go through save-set.
grant select on public.sets to authenticated;
revoke insert, update, delete on public.sets from authenticated;

-- the_line: read only, for the LINE history view. calculate-line writes it
-- with the service role.
grant select on public.the_line to authenticated;
revoke insert, update, delete on public.the_line from authenticated;

-- friendships: friend-request sends, accepts and declines under the caller's
-- JWT (005 policies).
grant select, insert, update on public.friendships to authenticated;

-- crews / crew_members: 006 keeps create, join and leave as direct client
-- operations, so the delete grants are deliberate -- "leave a crew" and
-- "disband a crew you created" are DELETEs.
grant select, insert, delete on public.crews to authenticated;
grant select, insert, delete on public.crew_members to authenticated;

-- invite_codes: create and view your own (007 policies). Redemption bumps
-- use_count through redeem-invite, so no UPDATE here.
grant select, insert on public.invite_codes to authenticated;
revoke update, delete on public.invite_codes from authenticated;

-- duels: read only. Participants view their duels; create, accept, decline and
-- resolve all run server-side.
grant select on public.duels to authenticated;
revoke insert, update, delete on public.duels from authenticated;

-- rankings: read your own. ELO is written only inside resolve_duel.
grant select on public.rankings to authenticated;
revoke insert, update, delete on public.rankings from authenticated;

-- ghost_records: read your own ghosts. save-set derives them.
grant select on public.ghost_records to authenticated;
revoke insert, update, delete on public.ghost_records from authenticated;

-- trash_talk_log: participants read, and mark a message seen (011 policies).
grant select, update on public.trash_talk_log to authenticated;
revoke insert, delete on public.trash_talk_log from authenticated;

-- duel_set_claims: internal bookkeeping with no policies at all. The claim
-- trigger is SECURITY DEFINER, so nothing client-facing needs reach here.
revoke all on public.duel_set_claims from authenticated, anon;

-- ---------------------------------------------------------------- service_role
-- Exactly what the authoritative Edge Functions use, enumerated per table
-- rather than granted wholesale.
grant select on public.users             to service_role;  -- friend-activity, crew-leaderboard
grant select on public.exercises         to service_role;
grant select on public.workout_sessions  to service_role;  -- friend-activity
grant select, insert on public.sets      to service_role;  -- save-set writes, resolve-duel reads challenger set
grant select, insert on public.the_line  to service_role;  -- calculate-line writes, crew-leaderboard reads
grant select, insert, update on public.friendships   to service_role;  -- redeem-invite
grant select on public.crews                          to service_role;  -- redeem-invite cap check
grant select, insert on public.crew_members           to service_role;  -- redeem-invite join
grant select, update on public.invite_codes           to service_role;  -- redeem-invite claim
grant select, insert, update on public.duels          to service_role;  -- create-duel, respond-duel
grant select, insert on public.trash_talk_log         to service_role;  -- generate-trash-talk
grant select, insert, update on public.ghost_records  to service_role;  -- save-set derivation

-- rankings and duel_set_claims are intentionally omitted: both are written
-- only from SECURITY DEFINER code (resolve_duel, claim_duel_sets), which runs
-- as the function owner rather than as service_role. Granting them here would
-- widen access beyond what any caller actually needs.

-- anon is granted nothing, deliberately. V1 has no unauthenticated surface.
revoke all on all tables in schema public from anon;
