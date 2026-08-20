// Genuine concurrent-transaction tests against the local Supabase Postgres.
//
// pgTAP covers schema, policies, grants and constraints well, but it runs in a
// single session and cannot show that two simultaneous transactions interleave
// correctly. Everything here opens real connections and deliberately overlaps
// them: one transaction takes a row lock and is held open while a second
// attempts the same operation, so the second genuinely blocks rather than
// merely running afterwards. Where a test cannot prove the general property
// (see the deadlock note at the bottom) it says so rather than implying it.
//
// Local CI instance only. No production credentials or project ref exist in
// this repo, and CI never runs `supabase link`.
import pg from "pg";

const CONN = process.env.DATABASE_URL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";

let passed = 0;
const failures = [];
const ok = (name, cond, detail = "") => {
  if (cond) {
    passed++;
    console.log("  ok   " + name);
  } else {
    failures.push(name + (detail ? "\n       " + detail : ""));
    console.log("  FAIL " + name);
  }
};

const connect = async () => {
  const c = new pg.Client({ connectionString: CONN });
  await c.connect();
  // A real hang must fail loudly rather than sit until the job timeout kills
  // the step with no output. Every intentional block in this file is released
  // within a second of the holding transaction committing, so these ceilings
  // only ever fire on a genuine stall.
  await c.query("set statement_timeout = '20s'");
  await c.query("set lock_timeout = '20s'");
  await c.query("set idle_in_transaction_session_timeout = '30s'");
  return c;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const U1 = "aaaaaaaa-0000-0000-0000-000000000001";
const U2 = "aaaaaaaa-0000-0000-0000-000000000002";
const U3 = "aaaaaaaa-0000-0000-0000-000000000003";
const EX = "bbbbbbbb-0000-0000-0000-000000000001";

async function seed(db) {
  for (const t of ["duel_set_claims", "duels", "ghost_records", "sets", "workout_sessions", "rankings", "invite_codes", "users"]) {
    await db.query("delete from public." + t);
  }
  await db.query("delete from auth.users where email like '%@conc.local'");

  for (const [id, email] of [[U1, "u1@conc.local"], [U2, "u2@conc.local"], [U3, "u3@conc.local"]]) {
    await db.query(
      "insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at) " +
      "values ($1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', $2, '', now(), now(), now())",
      [id, email],
    );
    await db.query("insert into public.users (id, email, preferred_units) values ($1, $2, 'lbs')", [id, email]);
  }

  await db.query(
    "insert into public.exercises (id, name, muscle_group, joint_config) values ($1, 'Concurrency Press', 'Chest', '{}'::jsonb) " +
    "on conflict (name) do update set joint_config = excluded.joint_config",
    [EX],
  );

  // 009 creates rankings via trigger on user insert; make sure they exist either way.
  for (const u of [U1, U2, U3]) {
    await db.query("insert into public.rankings (user_id) values ($1) on conflict (user_id) do nothing", [u]);
  }
}

async function makeSet(db, userId, weight, reps) {
  const s = await db.query("insert into public.workout_sessions (user_id, status) values ($1, 'completed') returning id", [userId]);
  const r = await db.query(
    "insert into public.sets (session_id, exercise_id, set_number, weight, reps_completed, reps_attempted, started_at) " +
    "values ($1, $2, 1, $3, $4, $4, now()) returning id",
    [s.rows[0].id, EX, weight, reps],
  );
  return r.rows[0].id;
}

async function makeDuel(db, challenger, opponent, challengerSet, opts) {
  const expiresAt = (opts && opts.expiresAt) || null;
  const status = (opts && opts.status) || "accepted";
  const r = await db.query(
    "insert into public.duels (challenger_id, opponent_id, exercise_id, challenger_set_id, status, expires_at, challenger_line_score) " +
    "values ($1,$2,$3,$4,$5, coalesce($6::timestamptz, now() + interval '48 hours'), 10) returning id",
    [challenger, opponent, EX, challengerSet, status, expiresAt],
  );
  return r.rows[0].id;
}

const eloOf = async (db, u) =>
  Number((await db.query("select elo_rating from public.rankings where user_id = $1", [u])).rows[0].elo_rating);

// resolve_duel returns a duels rowtype; a no-op transition yields a null record.
const transitioned = (res) => res.rows.length === 1 && res.rows[0] !== null && res.rows[0].id != null;

async function testExactlyOnceResolution(db) {
  console.log("\n[exactly-once duel resolution under real concurrency]");
  await seed(db);
  const cSet = await makeSet(db, U1, 100, 8);
  const oSet = await makeSet(db, U2, 120, 8);
  const duelId = await makeDuel(db, U1, U2, cSet);

  const beforeC = await eloOf(db, U1);
  const beforeO = await eloOf(db, U2);

  const a = await connect();
  const b = await connect();
  try {
    await a.query("BEGIN");
    await b.query("BEGIN");

    // A transitions the duel and HOLDS the row lock -- no commit yet.
    const ra = await a.query("select * from public.resolve_duel($1,$2,$3,$4,$5)", [duelId, U2, oSet, 25, U2]);

    // B issues the same call while A still holds the lock. Deliberately not
    // awaited yet: if this does not block, the two calls never overlapped and
    // the test would be proving nothing.
    let bSettled = false;
    const pb = b
      .query("select * from public.resolve_duel($1,$2,$3,$4,$5)", [duelId, U2, oSet, 25, U2])
      .then((res) => { bSettled = true; return res; });

    await sleep(700);
    ok("second resolver blocks while the first holds the row lock", bSettled === false,
       "It returned immediately, so the calls did not actually overlap.");

    await a.query("COMMIT");
    const rb = await pb;
    await b.query("COMMIT");

    ok("first resolver transitions the duel", transitioned(ra));
    ok("second resolver transitions nothing", !transitioned(rb),
       "second call returned: " + JSON.stringify(rb.rows[0]));

    const st = await db.query("select status from public.duels where id = $1", [duelId]);
    ok("duel ends up completed", st.rows[0].status === "completed");

    const afterC = await eloOf(db, U1);
    const afterO = await eloOf(db, U2);
    const movedC = Math.abs(afterC - beforeC);
    const movedO = Math.abs(afterO - beforeO);
    ok("ELO moved for both players", movedC > 0 && movedO > 0,
       "challenger " + beforeC + "->" + afterC + ", opponent " + beforeO + "->" + afterO);
    ok("ELO applied exactly once (within the K=32 bound)", movedC <= 32 && movedO <= 32,
       "a double application would exceed K. deltas " + movedC + "/" + movedO);

    const rec = await db.query("select wins, losses from public.rankings where user_id = $1", [U2]);
    ok("winner recorded exactly one win", Number(rec.rows[0].wins) === 1, "wins=" + rec.rows[0].wins);
  } finally {
    await a.end();
    await b.end();
  }
}

async function testExpiryRefusal(db) {
  console.log("\n[resolver refuses an expired duel]");
  await seed(db);
  const cSet = await makeSet(db, U1, 100, 8);
  const oSet = await makeSet(db, U2, 200, 10);
  const duelId = await makeDuel(db, U1, U2, cSet, { expiresAt: new Date(Date.now() - 60000).toISOString() });

  const before = await eloOf(db, U1);
  const r = await db.query("select * from public.resolve_duel($1,$2,$3,$4,$5)", [duelId, U2, oSet, 99, U2]);

  ok("expired duel cannot be resolved even while status is still accepted", !transitioned(r));
  ok("no ELO applied to an expired duel", (await eloOf(db, U1)) === before);

  const st = await db.query("select status from public.duels where id = $1", [duelId]);
  ok("expired duel is left un-completed", st.rows[0].status === "accepted");

  // The revised sweep must also be able to reach in_progress, which 008's did not.
  await db.query("update public.duels set status = 'in_progress' where id = $1", [duelId]);
  await db.query(
    "update public.duels set status = 'expired' where status in ('pending','accepted','in_progress') and expires_at < now()",
  );
  const swept = await db.query("select status from public.duels where id = $1", [duelId]);
  ok("revised sweep predicate expires an in_progress duel", swept.rows[0].status === "expired");
}

async function testSetClaimConcurrency(db) {
  console.log("\n[global set claim: concurrent duels racing for the same set]");
  await seed(db);
  const shared = await makeSet(db, U1, 100, 8);

  const a = await connect();
  const b = await connect();
  try {
    await a.query("BEGIN");
    await b.query("BEGIN");

    await a.query(
      "insert into public.duels (challenger_id, opponent_id, exercise_id, challenger_set_id, status) values ($1,$2,$3,$4,'pending')",
      [U1, U2, EX, shared],
    );

    let bSettled = false;
    const pb = b
      .query(
        "insert into public.duels (challenger_id, opponent_id, exercise_id, challenger_set_id, status) values ($1,$2,$3,$4,'pending')",
        [U1, U3, EX, shared],
      )
      .then(() => { bSettled = true; return "inserted"; })
      .catch((e) => { bSettled = true; return e.code; });

    await sleep(700);
    ok("second claim blocks on the first transaction", bSettled === false);

    await a.query("COMMIT");
    const outcome = await pb;
    try { await b.query("COMMIT"); } catch (e) { /* already aborted */ }

    ok("exactly one concurrent claim wins", outcome === "23505", "loser outcome: " + outcome);
    const n = await db.query("select count(*)::int as c from public.duel_set_claims where set_id = $1", [shared]);
    ok("exactly one claim row exists for the set", n.rows[0].c === 1, "rows=" + n.rows[0].c);
  } finally {
    await a.end();
    await b.end();
  }

  // Cross-role reuse: the case two per-column indexes could not express.
  const s2 = await makeSet(db, U1, 105, 8);
  await db.query(
    "insert into public.duels (challenger_id, opponent_id, exercise_id, challenger_set_id, status) values ($1,$2,$3,$4,'declined')",
    [U1, U2, EX, s2],
  );
  let crossRoleBlocked = false;
  try {
    await db.query(
      "insert into public.duels (challenger_id, opponent_id, exercise_id, opponent_set_id, status) values ($1,$2,$3,$4,'declined')",
      [U2, U1, EX, s2],
    );
  } catch (e) {
    crossRoleBlocked = e.code === "23505";
  }
  ok("a set used as a challenger set cannot be reused as an opponent set", crossRoleBlocked);
}

async function testInviteConcurrency(db) {
  console.log("\n[invite max_uses under concurrent redemption]");
  await seed(db);
  await db.query(
    "insert into public.invite_codes (code, kind, created_by, max_uses, use_count) values ('RACECODE', 'friend', $1, 1, 0)",
    [U1],
  );
  const id = (await db.query("select id from public.invite_codes where code = 'RACECODE'")).rows[0].id;

  const a = await connect();
  const b = await connect();
  try {
    await a.query("BEGIN");
    await b.query("BEGIN");

    // Both sides read use_count = 0, exactly as the Edge Function does, then
    // both attempt the compare-and-swap.
    const ra = await a.query(
      "update public.invite_codes set use_count = 1 where id = $1 and use_count = 0 returning id", [id],
    );

    let bSettled = false;
    const pb = b
      .query("update public.invite_codes set use_count = 1 where id = $1 and use_count = 0 returning id", [id])
      .then((r) => { bSettled = true; return r.rowCount; })
      .catch((e) => { bSettled = true; return "err:" + e.code; });

    await sleep(700);
    ok("second claimer blocks on the row lock", bSettled === false);

    await a.query("COMMIT");
    const bRows = await pb;
    await b.query("COMMIT");

    ok("first claimer wins", ra.rowCount === 1);
    ok("second claimer matches no row after re-evaluating", bRows === 0, "got " + bRows);

    const final = (await db.query("select use_count, max_uses from public.invite_codes where id = $1", [id])).rows[0];
    ok("use_count never exceeds max_uses", Number(final.use_count) <= Number(final.max_uses),
       "use_count=" + final.use_count + " max_uses=" + final.max_uses);
  } finally {
    await a.end();
    await b.end();
  }
}

async function testSharedPlayerConcurrency(db) {
  console.log("\n[two duels completing simultaneously around a shared player]");
  await seed(db);
  // U2 appears in both duels, so both resolvers touch the same ranking row.
  const c1 = await makeSet(db, U1, 100, 8);
  const o1 = await makeSet(db, U2, 110, 8);
  const c2 = await makeSet(db, U3, 100, 8);
  const o2 = await makeSet(db, U2, 115, 8);
  const d1 = await makeDuel(db, U1, U2, c1);
  const d2 = await makeDuel(db, U3, U2, c2);

  // Each side is BEGIN -> resolve -> COMMIT as one unit, and the two units are
  // started together. The previous version awaited both resolve_duel calls in a
  // single Promise.all before committing either, which cannot work: whichever
  // transaction wins the shared ranking row finishes its statement but is then
  // forbidden from committing until the other returns, and the other cannot
  // return until that row is released. That is a deadlock manufactured by the
  // test, not by the schema.
  //
  // Postgres said so, too. It reported 57014 (statement timeout), not 40P01
  // (deadlock detected). A genuine lock cycle would have been broken by the
  // deadlock detector in about a second; a plain wait means the second
  // transaction had acquired everything it needed and was simply being held
  // open by the harness.
  const resolveUnit = async (client, duelId, opponentSet) => {
    await client.query("BEGIN");
    try {
      const res = await client.query("select * from public.resolve_duel($1,$2,$3,$4,$5)",
                                     [duelId, U2, opponentSet, 20, U2]);
      await client.query("COMMIT");
      return res;
    } catch (e) {
      try { await client.query("ROLLBACK"); } catch (x) { /* already aborted */ }
      throw e;
    }
  };

  const a = await connect();
  const b = await connect();
  try {
    const [ra, rb] = await Promise.all([
      resolveUnit(a, d1, o1),
      resolveUnit(b, d2, o2),
    ]);
    ok("two duels sharing a player both resolve without deadlock", transitioned(ra) && transitioned(rb));
  } catch (e) {
    ok("two duels sharing a player both resolve without deadlock", false,
       e.code === "40P01" ? "deadlock detected (40P01) -- the lock ordering did not hold"
                          : "error " + e.code + ": " + e.message);
  } finally {
    await a.end();
    await b.end();
  }
  const r = (await db.query("select wins, losses, elo_rating from public.rankings where user_id = $1", [U2])).rows[0];
  ok("shared player has no partial ranking update", Number(r.wins) === 2,
     "wins=" + r.wins + " losses=" + r.losses + " elo=" + r.elo_rating);
}

// Watchdog. Without this a stall just burns the 20-minute job timeout and the
// step is killed before printing anything, which tells us nothing about where
// it stuck. Exiting non-zero means the workflow wrapper still emits the output
// as annotations, so the last [scenario] line shows the stall point.
const watchdog = setTimeout(() => {
  console.error("ERROR WATCHDOG: harness exceeded 240s; see the last [scenario] line for the stall point");
  process.exit(1);
}, 240000);
watchdog.unref?.();

const db = await connect();
try {
  await testExactlyOnceResolution(db);
  await testExpiryRefusal(db);
  await testSetClaimConcurrency(db);
  await testInviteConcurrency(db);
  await testSharedPlayerConcurrency(db);
} finally {
  await db.end();
  clearTimeout(watchdog);
}

console.log("\n" + passed + " passed, " + failures.length + " failed");
console.log(
  "\nNot proven here: that deadlock is impossible in general. This exercises one\n" +
  "concrete shared-player scenario and asserts it completes cleanly. Proving the\n" +
  "lock ordering is sufficient for every interleaving would need exhaustive or\n" +
  "randomised scheduling, which is out of scope for this gate.",
);
if (failures.length) {
  for (const f of failures) console.error("  x " + f);
  process.exit(1);
}
