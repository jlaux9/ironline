// Challenger references a set they already saved, picks an opponent +
// exercise, and creates the duel. challenger_line_score is computed now;
// opponent_line_score/winner are filled in by resolve-duel.
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

  const { opponent_id, exercise_id, set_id } = await req.json();
  if (!opponent_id || !exercise_id || !set_id) {
    return new Response(JSON.stringify({ error: "opponent_id, exercise_id, and set_id are required" }), { status: 400, headers: jsonHeaders });
  }
  if (opponent_id === user.id) {
    return new Response(JSON.stringify({ error: "can't duel yourself" }), { status: 400, headers: jsonHeaders });
  }

  // opponent_id is request input and gets interpolated into a raw PostgREST
  // .or() filter below, so it must be a well-formed UUID before it goes
  // anywhere near that string — same rule and same pattern as
  // friend-activity. (.eq() values are parameterised and don't need this;
  // hand-built filter strings do.)
  const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!uuidPattern.test(opponent_id)) {
    return new Response(JSON.stringify({ error: "opponent_id must be a valid uuid" }), { status: 400, headers: jsonHeaders });
  }

  // Duels are between friends (docs/framework.md §8 Phase 4). Previously any
  // authenticated user could challenge any other by raw user id, which made
  // unsolicited duels from strangers a spam and harassment vector.
  //
  // The friendships SELECT policy already scopes rows to ones the caller is
  // party to, so this read cannot be used to probe other people's friendships.
  // Both directions are checked because either side may have sent the request.
  const { data: friendship } = await supabase
    .from("friendships")
    .select("id")
    .eq("status", "accepted")
    .or(`and(user_id.eq.${user.id},friend_id.eq.${opponent_id}),and(user_id.eq.${opponent_id},friend_id.eq.${user.id})`)
    .maybeSingle();

  if (!friendship) {
    return new Response(
      JSON.stringify({ error: "you can only duel an accepted friend" }),
      { status: 403, headers: jsonHeaders },
    );
  }

  // RLS already scopes this to the caller's own sets — a set id belonging to
  // someone else is simply not visible here.
  const { data: set, error: setError } = await supabase
    .from("sets")
    .select("weight, reps_completed, exercise_id, started_at")
    .eq("id", set_id)
    .eq("exercise_id", exercise_id)
    .single();

  if (setError || !set) {
    return new Response(JSON.stringify({ error: "set not found for this exercise" }), { status: 400, headers: jsonHeaders });
  }

  // Keep the challenge tied to recent form rather than an all-time best dug
  // out of history. Matches the 48h duel lifetime.
  const setAgeMs = Date.now() - new Date(set.started_at).getTime();
  if (setAgeMs > 48 * 60 * 60 * 1000) {
    return new Response(
      JSON.stringify({ error: "set is too old to back a duel (48h limit)" }),
      { status: 400, headers: jsonHeaders },
    );
  }

  const { data: line } = await supabase
    .from("the_line")
    .select("predicted_weight, predicted_reps")
    .eq("exercise_id", exercise_id)
    .order("version", { ascending: false })
    .limit(1)
    .maybeSingle();

  let challengerLineScore: number | null = null;
  if (line) {
    const actual = estimatedOneRepMax(set.weight, set.reps_completed);
    const predicted = estimatedOneRepMax(line.predicted_weight, line.predicted_reps);
    challengerLineScore = ((actual - predicted) / predicted) * 100;
  }

  // 019 removes the client INSERT policy on duels, so this write goes through
  // the service role. Everything it authorizes was previously only advisory:
  // with a client-side INSERT policy that pinned nothing but challenger_id, a
  // caller could POST /duels directly and author opponent_id, the set, and
  // their own challenger_line_score. The checks above — accepted friendship,
  // caller owns the set (RLS-scoped read), exercise match, 48h age — plus the
  // server-computed score below are now the only way a duel gets created.
  //
  // challenger_id comes from the verified JWT, never from the request body.
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: duel, error } = await admin
    .from("duels")
    .insert({
      challenger_id: user.id,
      opponent_id,
      exercise_id,
      challenger_set_id: set_id,
      challenger_line_score: challengerLineScore,
      status: "pending",
    })
    .select()
    .single();

  if (error) {
    // Both integrity rules live in the database, not just here, so a retry or
    // a future caller cannot route around them. This only translates the
    // constraint violation into something a client can act on.
    //
    //   017  duels_active_matchup_uidx — one live duel per unordered friend
    //        pair per exercise
    //   016  duel_set_claims — one competitive use per set, across both
    //        roles; its trigger raises 23505 from duel_set_claims_pkey
    if (error.code === "23505") {
      const conflict = error.message.includes("duels_active_matchup_uidx")
        ? "you already have an active duel with this friend for this exercise"
        : "that set has already been used in a duel";
      return new Response(JSON.stringify({ error: conflict }), { status: 409, headers: jsonHeaders });
    }
    if (error.message?.includes("duel_set_claims")) {
      return new Response(
        JSON.stringify({ error: "that set has already been used in a duel" }),
        { status: 409, headers: jsonHeaders },
      );
    }
    return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: jsonHeaders });
  }

  return new Response(JSON.stringify({ duel }), { headers: jsonHeaders });
});
