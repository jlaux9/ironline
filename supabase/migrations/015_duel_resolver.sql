-- PHASE 1 of the duel-authority rollout — ADDITIVE ONLY, safe to apply while
-- the currently deployed Edge Functions are still running.
--
-- The previous draft created this resolver AND dropped the client duel
-- policies in one file, which had no safe ordering: deploying the new
-- resolve-duel first meant calling an RPC that did not exist yet, and
-- applying the migration first broke the old respond-duel, which relied on
-- the client UPDATE policy. Split so there is never a window where live
-- functionality is broken:
--
--   015 (this file)  create the resolver + grants        <- policies intact
--   016-018          additive integrity constraints      <- policies intact
--   deploy Edge Functions
--   019              remove client duel INSERT/UPDATE    <- functions ready
--   020              remove client set INSERT/UPDATE     <- functions ready
--
-- Nothing here changes existing behaviour: it adds a function nobody calls
-- until the new resolve-duel is deployed.
-- FINDING 2 (high) — resolve-duel could double-apply ELO.
-- It read the duel with status='accepted', then updated without reasserting
-- status, so a retry or a simultaneous second request could both pass the
-- read and both run the ELO block. The two ranking updates were also
-- separate statements, so they could partially apply or interleave with
-- another duel completing for the same player.
--
-- Fix: one function, one transaction. The status transition is a
-- compare-and-swap that only fires on accepted -> completed, and ELO is
-- computed from ranking rows locked in this same transaction. A second
-- caller finds no row to transition and returns null, having changed
-- nothing. ELO is computed here rather than passed in so it can never be
-- derived from rankings that changed between read and write.
create or replace function public.resolve_duel(
  p_duel_id uuid,
  p_opponent_id uuid,
  p_set_id uuid,
  p_opponent_line_score numeric,
  p_winner_id uuid
)
returns public.duels
language plpgsql
security definer
set search_path = public
as $$
declare
  v_duel public.duels;
  v_challenger public.rankings;
  v_opponent public.rankings;
  k constant integer := 32;
  v_challenger_result numeric;
  v_opponent_result numeric;
  v_challenger_expected numeric;
  v_opponent_expected numeric;
begin
  -- Compare-and-swap. `status = 'accepted'` is reasserted at the
  -- authoritative write, not merely checked beforehand.
  --
  -- expires_at is part of the same condition on purpose. The cron sweep in
  -- 008 only flips expired duels every 15 minutes, so status alone still
  -- reads 'accepted' for up to a quarter hour past the deadline. Checking
  -- expiry in the Edge Function instead would leave the same race — cron
  -- could flip the row between that check and this write. Making it part of
  -- the transition means an expired duel simply matches no row, and the
  -- caller gets the same null it gets for a retry.
  update public.duels
     set opponent_set_id      = p_set_id,
         opponent_line_score  = p_opponent_line_score,
         winner_id            = p_winner_id,
         status               = 'completed'
   where id          = p_duel_id
     and opponent_id = p_opponent_id
     and status      = 'accepted'
     and expires_at  > now()
  returning * into v_duel;

  -- Exactly-once: a retry or concurrent second request lands here and
  -- applies no ELO. Caller distinguishes this from success by the null.
  if v_duel.id is null then
    return null;
  end if;

  -- Lock both ranking rows in a stable order. Two duels sharing players and
  -- completing at the same moment would otherwise be able to deadlock.
  perform 1
     from public.rankings
    where user_id in (v_duel.challenger_id, v_duel.opponent_id)
    order by user_id
      for update;

  select * into v_challenger from public.rankings where user_id = v_duel.challenger_id;
  select * into v_opponent   from public.rankings where user_id = v_duel.opponent_id;

  -- A missing ranking row must not silently skip ELO while still reporting
  -- the duel completed. The trigger in 009 creates one per user, so this
  -- means the data is wrong; fail and roll the transition back with it.
  if v_challenger.user_id is null or v_opponent.user_id is null then
    raise exception 'missing ranking row for duel % participants', p_duel_id;
  end if;

  -- Draw when nobody won: both beat or both missed by the same margin.
  v_challenger_result := case
    when p_winner_id = v_duel.challenger_id then 1
    when p_winner_id = v_duel.opponent_id   then 0
    else 0.5
  end;
  v_opponent_result := 1 - v_challenger_result;

  v_challenger_expected := 1 / (1 + power(10, (v_opponent.elo_rating - v_challenger.elo_rating) / 400.0));
  v_opponent_expected   := 1 / (1 + power(10, (v_challenger.elo_rating - v_opponent.elo_rating) / 400.0));

  update public.rankings
     set elo_rating  = round(v_challenger.elo_rating + k * (v_challenger_result - v_challenger_expected)),
         wins        = v_challenger.wins   + case when v_challenger_result = 1 then 1 else 0 end,
         losses      = v_challenger.losses + case when v_challenger_result = 0 then 1 else 0 end,
         win_streak  = case when v_challenger_result = 1 then v_challenger.win_streak + 1 else 0 end,
         best_streak = greatest(
           v_challenger.best_streak,
           case when v_challenger_result = 1 then v_challenger.win_streak + 1 else 0 end
         )
   where user_id = v_duel.challenger_id;

  update public.rankings
     set elo_rating  = round(v_opponent.elo_rating + k * (v_opponent_result - v_opponent_expected)),
         wins        = v_opponent.wins   + case when v_opponent_result = 1 then 1 else 0 end,
         losses      = v_opponent.losses + case when v_opponent_result = 0 then 1 else 0 end,
         win_streak  = case when v_opponent_result = 1 then v_opponent.win_streak + 1 else 0 end,
         best_streak = greatest(
           v_opponent.best_streak,
           case when v_opponent_result = 1 then v_opponent.win_streak + 1 else 0 end
         )
   where user_id = v_duel.opponent_id;

  return v_duel;
end;
$$;

-- Only the service role calls this, from resolve-duel after it has verified
-- the caller. Revoking the default PUBLIC grant keeps it off the client API
-- surface; a SECURITY DEFINER function callable by anon/authenticated would
-- reintroduce the very authority hole this migration closes.
revoke all on function public.resolve_duel(uuid, uuid, uuid, numeric, uuid) from public;
revoke all on function public.resolve_duel(uuid, uuid, uuid, numeric, uuid) from anon, authenticated;

-- Only the service role may execute this. resolve-duel calls it with the
-- service-role client after authenticating the caller. The grant is explicit
-- rather than relying on service_role's implicit privileges, so the intended
-- permission is visible and verifiable in the schema.
grant execute on function public.resolve_duel(uuid, uuid, uuid, numeric, uuid) to service_role;
