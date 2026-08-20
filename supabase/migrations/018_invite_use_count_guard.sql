-- PHASE 1 (additive) — invite codes cannot exceed max_uses.
--
-- redeem-invite read use_count, compared it to max_uses, did the friendship
-- or crew work, then wrote `use_count + 1` as a literal at the end. Two
-- concurrent redemptions both read 0, both passed the check, and both wrote
-- 1 — so a single-use code could be redeemed repeatedly. Writing a literal
-- also meant this constraint alone would not have caught it, which is why
-- the function was changed to a compare-and-swap in the same commit.
--
-- This is the backstop: the invariant belongs to the table, so a future
-- writer — another function, a manual fix, a migration — cannot push past
-- the limit even if it forgets the compare-and-swap.
--
-- PREFLIGHT — fails if any existing code is already over its limit:
--
--   select id, code, use_count, max_uses
--     from public.invite_codes
--    where max_uses is not null and use_count > max_uses;
--
-- A non-empty result predates the fix and should be reconciled deliberately
-- (raise max_uses to match reality, or retire the code) rather than silently
-- clamped by the migration.
alter table public.invite_codes
  add constraint invite_codes_use_count_within_max
  check (max_uses is null or use_count <= max_uses);
