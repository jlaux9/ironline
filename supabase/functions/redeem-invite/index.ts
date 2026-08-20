// Redeems a friend or crew invite code. Uses the service role because the
// redeemer needs to read a code they didn't create, and for crew codes,
// write a membership row for a crew they don't belong to yet — both are
// outside what RLS allows the caller to do directly.
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

  const authedClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization")! } } },
  );
  const { data: { user }, error: authError } = await authedClient.auth.getUser();
  if (authError || !user) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: jsonHeaders });
  }

  const { code } = await req.json();
  if (!code) {
    return new Response(JSON.stringify({ error: "code is required" }), { status: 400, headers: jsonHeaders });
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const { data: invite, error: inviteError } = await admin
    .from("invite_codes")
    .select("*")
    .eq("code", code.toUpperCase())
    .maybeSingle();

  if (inviteError || !invite) {
    return new Response(JSON.stringify({ error: "invalid code" }), { status: 404, headers: jsonHeaders });
  }
  if (invite.expires_at && new Date(invite.expires_at) < new Date()) {
    return new Response(JSON.stringify({ error: "code expired" }), { status: 400, headers: jsonHeaders });
  }
  if (invite.created_by === user.id) {
    return new Response(JSON.stringify({ error: "you can't redeem your own code" }), { status: 400, headers: jsonHeaders });
  }

  if (invite.max_uses !== null && invite.use_count >= invite.max_uses) {
    return new Response(JSON.stringify({ error: "code has reached its use limit" }), { status: 400, headers: jsonHeaders });
  }

  // Claim a use before doing any work, with the value we read as the guard.
  // This used to read use_count, compare it to max_uses, and then write
  // `use_count + 1` as a literal at the end — so two concurrent redemptions
  // both read 0, both passed the check, and both wrote 1. A single-use code
  // could be redeemed repeatedly.
  //
  // Matching on the value we read makes the increment a compare-and-swap:
  // whoever commits first moves use_count, and the loser's filter no longer
  // matches, so it cannot overwrite. The check above still runs first purely
  // to give the ordinary "limit reached" case a clearer error than a lost
  // race would. Migration 018 adds a CHECK constraint as the backstop for any
  // future writer that forgets to do this.
  const { data: claimed, error: claimError } = await admin
    .from("invite_codes")
    .update({ use_count: invite.use_count + 1 })
    .eq("id", invite.id)
    .eq("use_count", invite.use_count)
    .select("id")
    .maybeSingle();

  if (claimError) {
    return new Response(JSON.stringify({ error: claimError.message }), { status: 400, headers: jsonHeaders });
  }
  if (!claimed) {
    return new Response(
      JSON.stringify({ error: "code was redeemed concurrently, try again" }),
      { status: 409, headers: jsonHeaders },
    );
  }

  if (invite.kind === "friend") {
    const a = invite.created_by;
    const b = user.id;

    const { data: existing } = await admin
      .from("friendships")
      .select("id, status")
      .or(`and(user_id.eq.${a},friend_id.eq.${b}),and(user_id.eq.${b},friend_id.eq.${a})`)
      .maybeSingle();

    if (existing) {
      if (existing.status !== "accepted") {
        await admin.from("friendships").update({ status: "accepted" }).eq("id", existing.id);
      }
    } else {
      const { error } = await admin.from("friendships").insert({ user_id: a, friend_id: b, status: "accepted" });
      if (error) return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: jsonHeaders });
    }
  } else {
    const { data: alreadyMember } = await admin
      .from("crew_members")
      .select("user_id")
      .eq("crew_id", invite.crew_id)
      .eq("user_id", user.id)
      .maybeSingle();

    if (!alreadyMember) {
      const { count } = await admin
        .from("crew_members")
        .select("*", { count: "exact", head: true })
        .eq("crew_id", invite.crew_id);

      const { data: crew } = await admin
        .from("crews")
        .select("max_members")
        .eq("id", invite.crew_id)
        .single();

      if (crew && count !== null && count >= crew.max_members) {
        return new Response(JSON.stringify({ error: "crew is full" }), { status: 400, headers: jsonHeaders });
      }

      const { error } = await admin
        .from("crew_members")
        .insert({ crew_id: invite.crew_id, user_id: user.id, role: "member" });
      if (error) return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: jsonHeaders });
    }
  }

  // The use was already claimed above, before any membership work — nothing
  // to increment here.
  return new Response(JSON.stringify({ ok: true, kind: invite.kind, crew_id: invite.crew_id }), { headers: jsonHeaders });
});
