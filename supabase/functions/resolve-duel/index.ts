// Opponent submits their set to resolve a duel: computes both
// line_scores, picks the winner (or draw), and updates both players' ELO
// in the same call. Kept atomic rather than three separate hops so a duel
// can't get stuck half-resolved if a later step fails.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";
import { estimatedOneRepMax } from "../_shared/line.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization")! } } },
  );

  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: jsonHeaders });
  }

  const { duel_id, set_id } = await req.json();
  if (!duel_id || !set_id) {
    return new Response(JSON.stringify({ error: "duel_id and set_id are required" }), { status: 400, headers: jsonHeaders });
  }

  const { data: duel, error: duelError } = await supabase
    .from("duels")
    .select("*")
    .eq("id", duel_id)
    .eq("opponent_id", user.id)
    .eq("status", "accepted")
    .single();

  if (duelError || !duel) {
    return new Response(JSON.stringify({ error: "duel not found or not ready to resolve" }), { status: 400, headers: jsonHeaders });
  }

  // Set eligibility. The user-scoped client is deliberate: RLS on `sets`
  // scopes SELECT to the caller's own sessions, so a set id belonging to
  // anyone else simply isn't visible here. That is the ownership check.
  const { data: opponentSet, error: setError } = await supabase
    .from("sets")
    .select("weight, reps_completed, exercise_id, started_at")
    .eq("id", set_id)
    .eq("exercise_id", duel.exercise_id)
    .single();

  if (setError || !opponentSet) {
    return new Response(JSON.stringify({ error: "set not found for this exercise" }), { status: 400, headers: jsonHeaders });
  }

  // The set has to have been performed *for this duel*. Without this, an old
  // personal best could be submitted to win a challenge issued today, which
  // defeats the point of a camera-verified contest. Duels expire in 48h, so
  // "after the duel was created" is a tight enough window on its own.
  if (new Date(opponentSet.started_at) <= new Date(duel.created_at)) {
    return new Response(
      JSON.stringify({ error: "set must be performed after the duel was created" }),
      { status: 400, headers: jsonHeaders },
    );
  }

  // Created here rather than just before the RPC because the baseline
  // fallback below also needs it. Everything above this point authenticated
  // and authorized the caller against this specific duel; the service role is
  // only used after that, and every read through it re-verifies ownership.
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: line } = await supabase
    .from("the_line")
    .select("predicted_weight, predicted_reps")
    .eq("exercise_id", duel.exercise_id)
    .order("version", { ascending: false })
    .limit(1)
    .maybeSingle();

  let opponentLineScore: number | null = null;
  if (line) {
    const actual = estimatedOneRepMax(opponentSet.weight, opponentSet.reps_completed);
    const predicted = estimatedOneRepMax(line.predicted_weight, line.predicted_reps);
    opponentLineScore = ((actual - predicted) / predicted) * 100;
  }

  // Higher line_score wins. If either side has no active LINE yet (still
  // in baseline), fall back to comparing raw e1RM so the duel can still resolve.
  let winnerId: string | null = null;
  const challengerScore = duel.challenger_line_score;
  if (challengerScore !== null && opponentLineScore !== null) {
    if (challengerScore > opponentLineScore) winnerId = duel.challenger_id;
    else if (opponentLineScore > challengerScore) winnerId = duel.opponent_id;
  } else {
    // Baseline fallback: at least one side has no LINE yet, so compare raw
    // e1RM instead.
    //
    // This read MUST NOT use the caller's client. RLS on `sets` scopes SELECT
    // to rows in the reader's own workout_sessions, so the opponent — who is
    // the caller here — cannot see the challenger's set at all. The previous
    // version did exactly that, silently got null, treated the challenger's
    // e1RM as 0, and handed the opponent the win on every baseline duel.
    //
    // Read it with the service role instead, but do not trust the duel row
    // alone: verify the set really belongs to the challenger and really is
    // for this duel's exercise. The join to workout_sessions is what proves
    // ownership, since `sets` has no user_id of its own.
    const { data: challengerSet } = await admin
      .from("sets")
      .select("weight, reps_completed, exercise_id, workout_sessions!inner(user_id)")
      .eq("id", duel.challenger_set_id)
      .eq("exercise_id", duel.exercise_id)
      .maybeSingle();

    const challengerSetIsValid = challengerSet
      && challengerSet.workout_sessions?.user_id === duel.challenger_id;

    if (!challengerSetIsValid) {
      // Refusing is the honest outcome. Scoring 0 for the challenger here is
      // what produced the original bias; a duel we cannot score fairly should
      // not be silently decided.
      return new Response(
        JSON.stringify({ error: "challenger set is missing or does not match this duel" }),
        { status: 409, headers: jsonHeaders },
      );
    }

    const challengerE1RM = estimatedOneRepMax(challengerSet.weight, challengerSet.reps_completed);
    const opponentE1RM = estimatedOneRepMax(opponentSet.weight, opponentSet.reps_completed);
    if (challengerE1RM > opponentE1RM) winnerId = duel.challenger_id;
    else if (opponentE1RM > challengerE1RM) winnerId = duel.opponent_id;
  }

  // The status transition and both ELO writes happen in one transaction
  // inside public.resolve_duel (migration 015). Previously this was an
  // unconditional UPDATE followed by two independent ranking updates, so a
  // retry could complete the duel twice and apply ELO twice, and a failure
  // between the two ranking writes left one player's rating moved and the
  // other's not.
  //
  // The function reasserts status='accepted' AND expires_at > now() at the
  // write itself, and returns null if no row transitioned — which is how both
  // a retry and an expired duel are detected. ELO is computed in there from
  // rows locked in the same transaction rather than being passed in, so it
  // cannot be derived from stale ratings.
  const { data: resolved, error: resolveError } = await admin.rpc("resolve_duel", {
    p_duel_id: duel_id,
    p_opponent_id: user.id,
    p_set_id: set_id,
    p_opponent_line_score: opponentLineScore,
    p_winner_id: winnerId,
  });

  if (resolveError) {
    return new Response(JSON.stringify({ error: resolveError.message }), { status: 400, headers: jsonHeaders });
  }

  // Lost the compare-and-swap: the duel was already resolved, or its deadline
  // passed. Report it rather than pretending this call is what completed it —
  // and, critically, apply no ELO.
  if (!resolved) {
    return new Response(
      JSON.stringify({ error: "duel already resolved or expired" }),
      { status: 409, headers: jsonHeaders },
    );
  }

  return new Response(JSON.stringify({ duel: resolved }), { headers: jsonHeaders });
});
