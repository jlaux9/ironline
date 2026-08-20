// Opponent accepts or declines a pending duel. Declining is terminal —
// no ELO change (docs/framework.md §7).
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

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

  const { duel_id, action } = await req.json();
  if (!duel_id || !["accept", "decline"].includes(action)) {
    return new Response(JSON.stringify({ error: "duel_id and action (accept/decline) are required" }), { status: 400, headers: jsonHeaders });
  }

  // 019 removes client UPDATE authority on duels, so this write goes through
  // the service role. The authorization it replaces is reproduced explicitly:
  // only this duel, only its opponent, only out of 'pending'. Those filters
  // are the whole permission check now — never relax them.
  //
  // The status filter also makes this a compare-and-swap: a double-tapped
  // accept transitions once and the second call matches no row.
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // expires_at is part of the filter, not a prior check. The cron sweep only
  // flips expired duels every 15 minutes, so a duel past its deadline still
  // reads 'pending' for up to that long — and checking expiry beforehand
  // would race with cron flipping the row. As part of the condition, an
  // expired duel simply matches nothing.
  const { data: duel, error } = await admin
    .from("duels")
    .update({ status: action === "accept" ? "accepted" : "declined" })
    .eq("id", duel_id)
    .eq("opponent_id", user.id)
    .eq("status", "pending")
    .gt("expires_at", new Date().toISOString())
    .select()
    .maybeSingle();

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: jsonHeaders });
  }

  if (!duel) {
    return new Response(
      JSON.stringify({ error: "duel not found, not yours to answer, already answered, or expired" }),
      { status: 409, headers: jsonHeaders },
    );
  }

  return new Response(JSON.stringify({ duel }), { headers: jsonHeaders });
});
