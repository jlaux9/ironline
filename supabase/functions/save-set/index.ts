// Inserts a completed set and flags it as a PR.
// PR = heaviest weight ever for this exercise (ties broken by more reps).
// A proper e1RM-based comparison belongs to THE LINE in Phase 2 — this is
// intentionally the simple V1 version.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";
import { estimatedOneRepMax } from "../_shared/line.ts";

interface SaveSetBody {
  session_id: string;
  exercise_id: string;
  set_number: number;
  weight: number;
  reps_completed: number;
  reps_attempted: number;
  rom_pass_rate?: number;
  started_at: string;
  ended_at?: string;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization")! } } },
  );

  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) {
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const body: SaveSetBody = await req.json();

  // Domain sanity only — NOT anti-cheat. These reject payloads that are
  // impossible on their face (negative reps, more completed than attempted, a
  // set that ended before it started). They do nothing about a plausible-but-
  // fabricated payload, which is the actual limit of this endpoint's trust;
  // see 020_set_authority.sql. The point is that obviously-broken data should
  // not reach the table and poison THE LINE, PRs and ghosts downstream.
  const isFinitePositive = (n: unknown) => typeof n === "number" && Number.isFinite(n) && n > 0;
  const isNonNegativeInt = (n: unknown) => typeof n === "number" && Number.isInteger(n) && n >= 0;
  const isValidTimestamp = (s: unknown) => typeof s === "string" && !Number.isNaN(Date.parse(s));

  const problems: string[] = [];
  if (!isFinitePositive(body.weight)) problems.push("weight must be a finite number greater than 0");
  if (!isNonNegativeInt(body.reps_completed)) problems.push("reps_completed must be a non-negative integer");
  if (!isNonNegativeInt(body.reps_attempted)) problems.push("reps_attempted must be a non-negative integer");
  if (isNonNegativeInt(body.reps_completed) && isNonNegativeInt(body.reps_attempted)
      && body.reps_completed > body.reps_attempted) {
    problems.push("reps_completed cannot exceed reps_attempted");
  }
  if (!Number.isInteger(body.set_number) || body.set_number < 1) problems.push("set_number must be a positive integer");
  if (body.rom_pass_rate !== undefined && body.rom_pass_rate !== null) {
    const rom = body.rom_pass_rate;
    if (typeof rom !== "number" || !Number.isFinite(rom) || rom < 0 || rom > 100) {
      problems.push("rom_pass_rate must be between 0 and 100");
    }
  }
  if (!isValidTimestamp(body.started_at)) problems.push("started_at must be a valid timestamp");
  if (body.ended_at !== undefined && body.ended_at !== null) {
    if (!isValidTimestamp(body.ended_at)) {
      problems.push("ended_at must be a valid timestamp");
    } else if (isValidTimestamp(body.started_at) && Date.parse(body.ended_at) < Date.parse(body.started_at)) {
      problems.push("ended_at cannot be before started_at");
    }
  }

  if (problems.length > 0) {
    return new Response(JSON.stringify({ error: "invalid set payload", problems }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // 020 removes the client INSERT/UPDATE policies on `sets`, so the write
  // below goes through the service role. That policy was what previously
  // scoped a set to the caller's own session, so the check has to be made
  // explicitly here — otherwise moving to the service role would widen the
  // hole instead of closing it.
  //
  // Read with the caller's own JWT on purpose: RLS on workout_sessions means
  // a session id belonging to anyone else simply isn't visible, so this both
  // proves existence and proves ownership in one query.
  const { data: session, error: sessionError } = await supabase
    .from("workout_sessions")
    .select("id")
    .eq("id", body.session_id)
    .maybeSingle();

  if (sessionError) {
    return new Response(JSON.stringify({ error: sessionError.message }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  if (!session) {
    return new Response(JSON.stringify({ error: "session not found for this user" }), {
      status: 403,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: priorBest, error: priorError } = await supabase
    .from("sets")
    .select("weight, reps_completed")
    .eq("exercise_id", body.exercise_id)
    .order("weight", { ascending: false })
    .order("reps_completed", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (priorError) {
    return new Response(JSON.stringify({ error: priorError.message }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const isPr = !priorBest ||
    body.weight > priorBest.weight ||
    (body.weight === priorBest.weight && body.reps_completed > priorBest.reps_completed);

  // Service-role write: after 020 there is no client INSERT policy on sets.
  // Ownership was proven above by reading the session under the caller's JWT.
  // Note the prior-best read above deliberately stays on the caller's client
  // so is_pr is still computed against that user's own history only.
  // Explicit column list rather than `{ ...body }`. Spreading the parsed
  // request meant any extra key the caller invented was handed straight to
  // the insert — harmless today only because no current column happens to be
  // exploitable, which is not a property worth relying on. Now the request
  // can only ever set the fields listed here, and is_pr stays server-derived.
  const { data: set, error } = await admin
    .from("sets")
    .insert({
      session_id: body.session_id,
      exercise_id: body.exercise_id,
      set_number: body.set_number,
      weight: body.weight,
      reps_completed: body.reps_completed,
      reps_attempted: body.reps_attempted,
      rom_pass_rate: body.rom_pass_rate ?? null,
      started_at: body.started_at,
      ended_at: body.ended_at ?? null,
      is_pr: isPr,
    })
    .select()
    .single();

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Ghost bookkeeping (docs/framework.md §8 Phase 4): every set becomes a
  // ghost record, and any of the user's prior unbeaten ghosts this set's
  // e1RM surpasses get marked beaten.
  const { data: priorGhosts } = await supabase
    .from("ghost_records")
    .select("id, weight, reps")
    .eq("exercise_id", body.exercise_id)
    .eq("beaten", false);

  const newE1RM = estimatedOneRepMax(body.weight, body.reps_completed);
  const beatenIds = (priorGhosts ?? [])
    .filter((g) => estimatedOneRepMax(g.weight, g.reps) < newE1RM)
    .map((g) => g.id);

  // Ghost writes go through the service role after 021 removes the client
  // INSERT/UPDATE policies. The reads above deliberately stay on the caller's
  // client so "which ghosts did this beat" is still answered from that user's
  // own records only; the writes below are scoped by ids derived from that
  // scoped read, plus user.id from the verified JWT.
  if (beatenIds.length > 0) {
    await admin
      .from("ghost_records")
      .update({ beaten: true, beaten_by_set_id: set.id })
      .in("id", beatenIds);
  }

  await admin.from("ghost_records").insert({
    user_id: user.id,
    exercise_id: body.exercise_id,
    set_id: set.id,
    weight: body.weight,
    reps: body.reps_completed,
  });

  return new Response(JSON.stringify({ set }), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
