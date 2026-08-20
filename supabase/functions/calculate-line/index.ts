// Recalculates THE LINE for the authenticated user × exercise.
//
// Core V1 model:
//   1. last N sets (max 30)
//   2. e1RM per set via Epley
//   3. recency weighting, half-life 14 days
//   4. LINE = weighted avg e1RM x 0.92
//   5. convert back to weight x reps using typical rep count
//   6. confidence = min(sessions / 10, 1.0)
//
// Important authority rule: the user-scoped client is used for authentication
// and RLS-protected reads. Only the service-role client may write THE LINE, so
// a client cannot author a the_line row directly.
//
// That is a statement about write paths, not about trustworthiness. THE LINE
// is derived from `sets`, and save-set stores the rep/weight/ROM values its
// caller reports — so a fabricated set still produces a "legitimately"
// computed LINE. See 020_set_authority.sql for where that boundary actually
// sits.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";
import { estimatedOneRepMax, predictedWeightFor } from "../_shared/line.ts";

const HALF_LIFE_DAYS = 14;
const LINE_MULTIPLIER = 0.92;
const MIN_SESSIONS = 3;
const BEAT_STREAK_BONUS = 1.02;
const MISS_STREAK_DAMPING = 0.3;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

  const supabase = createClient(
    supabaseUrl,
    anonKey,
    { global: { headers: { Authorization: req.headers.get("Authorization")! } } },
  );
  const admin = createClient(supabaseUrl, serviceRoleKey);

  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const { exercise_id } = await req.json();
  if (!exercise_id) {
    return new Response(JSON.stringify({ error: "exercise_id is required" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const { data: sets, error: setsError } = await supabase
    .from("sets")
    .select("weight, reps_completed, session_id, started_at")
    .eq("exercise_id", exercise_id)
    .order("started_at", { ascending: false })
    .limit(30);

  if (setsError) {
    return new Response(JSON.stringify({ error: setsError.message }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const sessionsCount = new Set((sets ?? []).map((s) => s.session_id)).size;
  if (sessionsCount < MIN_SESSIONS) {
    return new Response(
      JSON.stringify({ baseline: true, sessions_remaining: MIN_SESSIONS - sessionsCount }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }

  const now = Date.now();
  let weightedSum = 0;
  let weightTotal = 0;
  let repsSum = 0;

  for (const s of sets!) {
    const e1RM = estimatedOneRepMax(s.weight, s.reps_completed);
    const ageDays = (now - new Date(s.started_at).getTime()) / 86_400_000;
    const recencyWeight = Math.pow(0.5, ageDays / HALF_LIFE_DAYS);
    weightedSum += e1RM * recencyWeight;
    weightTotal += recencyWeight;
    repsSum += s.reps_completed;
  }

  let lineE1RM = (weightedSum / weightTotal) * LINE_MULTIPLIER;
  const typicalReps = Math.max(1, Math.round(repsSum / sets!.length));

  const { data: previous } = await supabase
    .from("the_line")
    .select("predicted_weight, predicted_reps, version")
    .eq("exercise_id", exercise_id)
    .order("version", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (previous) {
    const prevE1RM = estimatedOneRepMax(previous.predicted_weight, previous.predicted_reps);

    // Three wins/misses means three distinct sessions, not three sets from one workout.
    const bestBySession = new Map<string, number>();
    for (const s of sets!) {
      const e1RM = estimatedOneRepMax(s.weight, s.reps_completed);
      bestBySession.set(s.session_id, Math.max(bestBySession.get(s.session_id) ?? 0, e1RM));
    }

    const recentSessionIds: string[] = [];
    for (const s of sets!) {
      if (!recentSessionIds.includes(s.session_id)) recentSessionIds.push(s.session_id);
      if (recentSessionIds.length === 3) break;
    }

    if (recentSessionIds.length === 3) {
      const last3Sessions = recentSessionIds.map((id) => bestBySession.get(id)!);
      const allBeat = last3Sessions.every((e) => e > prevE1RM);
      const allMissed = last3Sessions.every((e) => e < prevE1RM);

      if (allBeat) {
        lineE1RM *= BEAT_STREAK_BONUS;
      } else if (allMissed) {
        lineE1RM = prevE1RM * (1 - MISS_STREAK_DAMPING) + lineE1RM * MISS_STREAK_DAMPING;
      }
    }
  }

  const predictedWeight = Math.round(predictedWeightFor(lineE1RM, typicalReps) * 10) / 10;
  const confidence = Math.min(sessionsCount / 10, 1.0);
  const version = (previous?.version ?? 0) + 1;

  const { data: line, error: insertError } = await admin
    .from("the_line")
    .insert({
      user_id: user.id,
      exercise_id,
      predicted_weight: predictedWeight,
      predicted_reps: typicalReps,
      confidence,
      baseline_sessions: sessionsCount,
      version,
    })
    .select()
    .single();

  if (insertError) {
    return new Response(JSON.stringify({ error: insertError.message }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ line }), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
