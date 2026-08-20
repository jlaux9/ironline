-- Forward-only continuation of the applied production history (001-012).
-- Originally authored as 005_line_authority.sql on the camera/referee fork,
-- where it was never applied to production. Renumbered to follow 012 rather
-- than rewriting applied history. Behaviour is unchanged from the original.
--
-- THE LINE is competitive game state. Clients may read their own LINE history,
-- but only the calculate-line Edge Function (service role) should create rows.
-- Production 004_the_line.sql granted clients a direct INSERT policy, which
-- lets a client author its own competitive state. This closes that gap; there
-- are no UPDATE or DELETE policies on the_line, so after this migration the
-- table is read-only for clients.
--
-- DEPLOY ORDER — deploy the service-role calculate-line BEFORE applying this.
-- The function currently deployed to production inserts using the caller's JWT,
-- so dropping the policy first would break LINE recalculation until the new
-- function ships. The new function writes with the service role, which bypasses
-- RLS, so it works both before and after this migration. Function first, then
-- this. Never the reverse.
--
-- PRE-FLIGHT — the unique index below fails if production already holds
-- duplicate (user_id, exercise_id, version) rows. The previous read-then-insert
-- versioning in calculate-line could produce those under concurrency, so this
-- is not hypothetical. Check first:
--
--   select user_id, exercise_id, version, count(*)
--   from public.the_line
--   group by 1, 2, 3
--   having count(*) > 1;
--
-- If that returns rows, STOP and decide how to collapse them deliberately —
-- do not let a migration silently delete competitive history. This file runs
-- in a transaction, so a failure here rolls the policy drop back with it and
-- leaves production exactly as it was.

drop policy if exists "Users can insert their own LINE rows" on public.the_line;

-- Prevent duplicate versions if calculate-line is invoked concurrently.
create unique index if not exists the_line_user_exercise_version_uidx
  on public.the_line(user_id, exercise_id, version);
