// Static regression guards for the game-integrity findings fixed in
// migrations 015-020.
//
// These are not a substitute for database integration tests — they cannot
// prove the compare-and-swap actually serialises under concurrency, only a
// real Postgres can. What they do is stop the *shape* of each fix from being
// silently undone by a later edit, which is the realistic regression: someone
// adds a convenience UPDATE policy, or drops the status filter "because the
// caller already checked it".
//
// Runs on plain Node (no Deno, no DB, no network) so it can gate every PR.
// Usage: node supabase/checks/authority-invariants.mjs

import { readFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (p) => readFileSync(join(root, p), "utf8");

// SQL assertions must read the DDL, never the commentary around it. These
// migrations document their own preflight queries in `--` headers, so a naive
// match happily finds `least(challenger_id, opponent_id)` in a comment and
// passes while the actual index says something else entirely. That was a real
// false pass, caught by mutation-testing this file. Strip comments first.
// (Safe here: no migration has `--` inside a string literal.)
const readSql = (p) =>
  read(p)
    .split("\n")
    .map((line) => line.replace(/--.*$/, ""))
    .join("\n");

const migrations = readdirSync(join(root, "migrations")).sort();

// Edge Function sources, read once up front so assertion order is free.
const createDuel = read("functions/create-duel/index.ts");
const resolveFn  = read("functions/resolve-duel/index.ts");
const respondFn  = read("functions/respond-duel/index.ts");
const saveSet    = read("functions/save-set/index.ts");

const failures = [];
const check = (name, condition, detail) => {
  if (!condition) failures.push(`${name}\n    ${detail}`);
};

// ---------------------------------------------------------------- finding 1
// Clients must not be able to author duel outcomes OR duels themselves.
const duelAuthority = readSql("migrations/019_duel_authority.sql");

check(
  "019 drops the client UPDATE policy on duels",
  /drop\s+policy\s+if\s+exists\s+"Opponent can respond to and resolve a duel"\s+on\s+public\.duels/i.test(duelAuthority),
  "Without this, an opponent can PATCH /duels and set winner_id themselves.",
);

check(
  "019 drops the client INSERT policy on duels",
  /drop\s+policy\s+if\s+exists\s+"Challenger can create a duel"\s+on\s+public\.duels/i.test(duelAuthority),
  "008's INSERT policy pinned only challenger_id, so a client could POST a duel with a forged opponent, set and line score — making create-duel's checks advisory.",
);

// A later migration re-granting a write reopens the hole. "Later" has to be
// measured from the migration that revokes it, not from an arbitrary floor:
// the original CREATE POLICY for each table is legitimate history and must
// not be flagged. (An earlier version used a fixed `> 008`, which happened to
// work for duels and sets but wrongly flagged 010 — the migration that
// creates the ghost policies 021 later drops.)
const migrationsAfter = (n) => migrations.filter((f) => Number(f.slice(0, 3)) > n);

const regrantsAfter = (table, verb, afterNumber) =>
  migrationsAfter(afterNumber).filter((f) =>
    new RegExp(`create\\s+policy[^;]*on\\s+public\\.${table}\\s+for\\s+${verb}`, "is").test(readSql(join("migrations", f)))
  );
for (const verb of ["insert", "update"]) {
  const offenders = regrantsAfter("duels", verb, 19);
  check(
    `no migration re-grants client ${verb.toUpperCase()} on duels`,
    offenders.length === 0,
    `Re-granting it reopens finding 1. Offending: ${offenders.join(", ")}`,
  );
}

// ------------------------------------------------ set write authority (V1)
// `sets` is the root of every competitive number. Direct client writes would
// bypass the camera referee entirely.
const setAuthority = readSql("migrations/020_set_authority.sql");

for (const [verb, policy] of [
  ["insert", "Users can insert sets into their own sessions"],
  ["update", "Users can update sets from their own sessions"],
]) {
  check(
    `020 drops the client ${verb.toUpperCase()} policy on sets`,
    new RegExp(`drop\\s+policy\\s+if\\s+exists\\s+"${policy}"\\s+on\\s+public\\.sets`, "i").test(setAuthority),
    "A direct PostgREST write could forge reps, weight and ROM.",
  );

  const offenders = regrantsAfter("sets", verb, 20);
  check(
    `no migration re-grants client ${verb.toUpperCase()} on sets`,
    offenders.length === 0,
    `Offending: ${offenders.join(", ")}`,
  );
}


check(
  "save-set verifies the session belongs to the caller",
  /from\(["']workout_sessions["']\)[\s\S]{0,300}?eq\(\s*["']id["']\s*,\s*body\.session_id/.test(saveSet),
  "The dropped policy was what scoped a set to its owner; without an explicit check, moving to service role widens the hole.",
);

check(
  "save-set writes the set with the service role",
  /await\s+admin\s*\n?\s*\.from\(["']sets["']\)\s*\n?\s*\.insert\(/.test(saveSet),
  "After 020 there is no client INSERT policy on sets, so a user-scoped write would fail.",
);

// ---------------------------------------------------------------- finding 2
// A duel transitions accepted -> completed exactly once, and ELO moves with it.
const resolveSql = readSql("migrations/015_duel_resolver.sql");

check(
  "resolve_duel reasserts status='accepted' at the authoritative write",
  /update\s+public\.duels[\s\S]*?where[\s\S]*?status\s*=\s*'accepted'/i.test(resolveSql),
  "Checking status before the UPDATE instead of within it allows double resolution.",
);

check(
  "resolve_duel returns null when no row transitions",
  /if\s+v_duel\.id\s+is\s+null\s+then[\s\S]*?return\s+null/i.test(resolveSql),
  "The retry path must apply no ELO and must be distinguishable by the caller.",
);

check(
  "resolve_duel locks both ranking rows in a stable order",
  /order\s+by\s+user_id[\s\S]*?for\s+update/i.test(resolveSql),
  "Unordered locking lets two duels sharing players deadlock.",
);

check(
  "resolve_duel is not callable by anon/authenticated",
  /revoke\s+all\s+on\s+function\s+public\.resolve_duel[\s\S]*?from\s+anon,\s*authenticated/i.test(resolveSql),
  "A SECURITY DEFINER resolver exposed to clients reopens finding 1 through the back door.",
);

check(
  "resolve_duel grants EXECUTE to service_role explicitly",
  /grant\s+execute\s+on\s+function\s+public\.resolve_duel[\s\S]{0,120}?to\s+service_role/i.test(resolveSql),
  "resolve-duel calls this with the service-role client; relying on implicit privilege leaves the intended grant invisible and unverifiable.",
);

// The resolver migration must stay additive so it can be applied before the
// new Edge Functions are deployed. If it also dropped policies there would be
// no safe ordering: deploy first and the RPC is missing, migrate first and the
// live respond-duel loses its write path.
check(
  "the resolver migration drops no policy (deploy-order safety)",
  !/drop\s+policy/i.test(resolveSql),
  "015 must be additive. Policy removal belongs in 019/020, after the functions are deployed.",
);

check(
  "resolve-duel goes through the RPC",
  /\.rpc\(\s*["']resolve_duel["']/.test(resolveFn),
  "Direct writes from the function cannot be atomic with the ELO update.",
);

check(
  "resolve-duel no longer updates duels directly",
  !/from\(["']duels["']\)[\s\S]{0,200}?\.update\(/.test(resolveFn),
  "Any direct duel UPDATE here bypasses the compare-and-swap.",
);

check(
  "resolve-duel treats a lost compare-and-swap as a conflict",
  /if\s*\(\s*!resolved\s*\)/.test(resolveFn),
  "Ignoring the null return would report a retry as a fresh resolution.",
);

// ---------------------------------------------------------------- finding 6
check(
  "resolve-duel requires the set to postdate the duel",
  /started_at[\s\S]{0,200}?duel\.created_at/.test(resolveFn),
  "Without this an old personal best can win a challenge issued today.",
);

// ------------------------------------------- baseline fallback correctness
// The opponent is the caller, and RLS on `sets` scopes SELECT to the reader's
// own sessions — so reading the challenger's set on the caller's client
// silently returns null and hands the opponent every baseline duel.
const fallbackBlock = (resolveFn.match(/\}\s*else\s*\{[\s\S]*?challengerE1RM[\s\S]*?\}/) ?? [""])[0];

check(
  "baseline fallback reads the challenger set with the service role",
  /await\s+admin\s*\n?\s*\.from\(["']sets["']\)/.test(fallbackBlock),
  "Reading it on the caller's client returns null under RLS and biases the result to the opponent.",
);

check(
  "baseline fallback verifies the challenger set's owner",
  /workout_sessions[\s\S]{0,300}?duel\.challenger_id/.test(fallbackBlock),
  "The duel row naming a set id is not proof the set belongs to the challenger.",
);

check(
  "baseline fallback verifies the challenger set's exercise",
  /eq\(\s*["']exercise_id["']\s*,\s*duel\.exercise_id\s*\)/.test(fallbackBlock),
  "A set for a different lift must not decide this duel.",
);

check(
  "baseline fallback refuses rather than scoring the challenger 0",
  /if\s*\(\s*!challengerSetIsValid\s*\)[\s\S]*?status:\s*409/.test(resolveFn)
    && !/challengerSet\s*\?[\s\S]{0,80}?:\s*0/.test(resolveFn),
  "Defaulting a missing challenger set to 0 e1RM is what produced the original bias.",
);

// --------------------------------------------- request-input UUID validation
// Values interpolated into raw PostgREST filter strings must be validated
// first. .eq() is parameterised and is intentionally not in scope here.
check(
  "create-duel validates opponent_id before raw .or() interpolation",
  /uuidPattern[\s\S]{0,200}?test\(\s*opponent_id\s*\)/.test(createDuel)
    && createDuel.indexOf("uuidPattern.test(opponent_id)") < createDuel.indexOf(".or(`"),
  "opponent_id is request input and reaches a hand-built filter string.",
);

check(
  "friend-activity still validates its request-supplied id",
  /uuidPattern[\s\S]{0,200}?test\(\s*friendId\s*\)/.test(read("functions/friend-activity/index.ts")),
  "This was already correct; the check exists so it stays that way.",
);

// ------------------------------------------------------- duel expiry at write
check(
  "resolve_duel makes expiry part of the transition condition",
  /and\s+expires_at\s*>\s*now\(\)/i.test(resolveSql),
  "Checking expiry before the write races the 15-minute cron sweep.",
);

check(
  "respond-duel refuses expired duels in the same filter",
  /\.gt\(\s*["']expires_at["']/.test(respondFn),
  "A duel past its deadline still reads 'pending' until cron sweeps it.",
);

// --------------------------------------------------------- ghost authority
const ghostAuthority = readSql("migrations/021_duel_expiry_and_ghost_authority.sql");

for (const [verb, policy] of [
  ["insert", "Users can insert their own ghost records"],
  ["update", "Users can update their own ghost records"],
]) {
  check(
    `021 drops the client ${verb.toUpperCase()} policy on ghost_records`,
    new RegExp(`drop\\s+policy\\s+if\\s+exists\\s+"${policy}"\\s+on\\s+public\\.ghost_records`, "i").test(ghostAuthority),
    "Ghosts are derived state; a client must not be able to invent one or mark one beaten.",
  );

  const offenders = regrantsAfter("ghost_records", verb, 21);
  check(
    `no migration re-grants client ${verb.toUpperCase()} on ghost_records`,
    offenders.length === 0,
    `Offending: ${offenders.join(", ")}`,
  );
}

check(
  "save-set writes ghost records with the authoritative client",
  !/await\s+supabase\s*\n?\s*\.from\(["']ghost_records["']\)\s*\n?\s*\.(update|insert)\(/.test(saveSet)
    && /await\s+admin[\s\S]{0,80}?from\(["']ghost_records["']\)[\s\S]{0,120}?\.update\(/.test(saveSet)
    && /admin\.from\(["']ghost_records["']\)\.insert\(/.test(saveSet),
  "After 021 there are no client ghost write policies, so a user-scoped write would fail.",
);

check(
  "021 sweeps in_progress so no duel state is immortal",
  /status\s+in\s*\(\s*'pending',\s*'accepted',\s*'in_progress'\s*\)\s*and\s*expires_at\s*<\s*now\(\)/i.test(ghostAuthority),
  "008's sweep skips in_progress; with expiry now in the transition conditions, such a duel could never expire, be answered, or be resolved.",
);

// ------------------------------------------------------ data API privileges
// 022 makes the Data API grants explicit. A fresh chain granted nothing at all,
// so production only worked via ambient default privileges that live in the
// project rather than in this repo. Guard both halves of the model.
const privileges = readSql("migrations/022_data_api_privileges.sql");

for (const t of ["sets", "the_line", "duels", "ghost_records"]) {
  check(
    `022 revokes authenticated write on ${t}`,
    new RegExp(`revoke[^;]*on public.${t} from authenticated`, "is").test(privileges),
    "A grant would re-open the write path the authority migrations closed.",
  );
  check(
    `022 still grants authenticated SELECT on ${t}`,
    new RegExp(`grant select[^;]*on public.${t} to authenticated`, "is").test(privileges),
    "Owner-scoped reads must keep working; RLS decides which rows.",
  );
}

check(
  "022 grants anon nothing",
  !/grant[^;]*to[^;]*anon/is.test(privileges) && /revoke all on all tables in schema public from anon/i.test(privileges),
  "V1 has no unauthenticated surface; granting anon widens attack surface for no feature.",
);

check(
  "022 avoids blanket ALL grants",
  !/grants+alls+(privilegess+)?on/i.test(privileges),
  "Privileges are enumerated per table on purpose.",
);
// -------------------------------------------------- save-set input hygiene
check(
  "save-set rejects impossible payloads",
  /reps_completed cannot exceed reps_attempted/.test(saveSet)
    && /ended_at cannot be before started_at/.test(saveSet),
  "Domain sanity, so obviously-broken data cannot poison THE LINE, PRs and ghosts.",
);

check(
  "save-set builds its insert payload explicitly",
  !/\.insert\(\s*\{\s*\.\.\.body/.test(saveSet),
  "Spreading the parsed request hands any invented key straight to the insert.",
);

// Global, across BOTH roles. Two per-column indexes would only make a set
// unique within each role, still allowing challenger-set on one duel and
// opponent-set on another.
const setClaims = readSql("migrations/016_duel_set_claims.sql");

check(
  "016 keys duel_set_claims on set_id alone",
  /create\s+table[\s\S]*?duel_set_claims\s*\([\s\S]*?set_id\s+uuid\s+primary\s+key/i.test(setClaims),
  "Uniqueness has to span both roles; only a set_id-keyed table expresses that.",
);

check(
  "016 claims sets via trigger on duels",
  /create\s+trigger\s+duels_claim_sets[\s\S]*?on\s+public\.duels/i.test(setClaims),
  "The claim must share the duel's transaction, so a losing race takes the duel write down with it.",
);

check(
  "016 backfills existing duels",
  /insert\s+into\s+public\.duel_set_claims[\s\S]*?from\s+public\.duels/i.test(setClaims),
  "Historical duels must be covered or their sets stay replayable.",
);

// Scope this to the trigger function body rather than the whole file. The
// backfill above it legitimately uses `on conflict do nothing`, so a
// file-wide match would either always fail or — as an earlier version of this
// check did — depend on how much comment text happened to sit between them.
const claimFnBody = (setClaims.match(
  /create\s+or\s+replace\s+function\s+public\.claim_duel_sets\(\)[\s\S]*?\$\$;/i,
) ?? [""])[0];

check(
  "the claim trigger body exists and inserts both roles",
  /new\.challenger_set_id/.test(claimFnBody) && /new\.opponent_set_id/.test(claimFnBody),
  "Both the challenger's and the opponent's set must be claimed.",
);

check(
  "the claim trigger does not swallow conflicts",
  claimFnBody.length > 0 && !/on\s+conflict/i.test(claimFnBody),
  "New claims must raise so a losing race aborts the duel write; only the backfill may skip duplicates.",
);

// ---------------------------------------------------------------- finding 5

check(
  "create-duel requires an accepted friendship",
  /from\(["']friendships["']\)[\s\S]{0,400}?accepted/.test(createDuel),
  "Otherwise any user can challenge any other by raw user id.",
);

const matchup = readSql("migrations/017_duel_matchup_uniqueness.sql");

check(
  "017 keys the active matchup on the unordered pair",
  /least\s*\(\s*challenger_id\s*,\s*opponent_id\s*\)[\s\S]*?greatest\s*\(\s*challenger_id\s*,\s*opponent_id\s*\)/i.test(matchup),
  "Keying on (challenger, opponent) lets A->B and B->A both be live for the same exercise.",
);

// Must cover every non-terminal state 008's check constraint allows, not just
// the two the Edge Functions currently write. A duel parked in 'in_progress'
// would otherwise sit outside the index and let a second live duel open for
// the same pair and exercise.
check(
  "017 covers all three active states",
  /where\s+status\s+in\s*\(\s*'pending',\s*'accepted',\s*'in_progress'\s*\)/i.test(matchup),
  "Omitting 'in_progress' leaves a hole; including a terminal state would block rematches.",
);

for (const terminal of ["completed", "declined", "expired"]) {
  check(
    `017 does not treat '${terminal}' as active`,
    !new RegExp(`where\\s+status\\s+in[^)]*'${terminal}'`, "i").test(matchup),
    "Rematches must be allowed once a duel reaches a terminal state.",
  );
}

// ---------------------------------------------------------------- finding 4
const redeem = read("functions/redeem-invite/index.ts");

check(
  "redeem-invite claims a use with a compare-and-swap",
  /\.update\(\s*\{\s*use_count:[\s\S]{0,120}?\.eq\(\s*["']use_count["']/.test(redeem),
  "Incrementing without matching the value read allows a lost update.",
);

check(
  "redeem-invite increments exactly once",
  (redeem.match(/use_count:\s*invite\.use_count\s*\+\s*1/g) || []).length === 1,
  "The original trailing unconditional increment must not coexist with the claim.",
);

check(
  "018 backstops the limit at the table",
  /check\s*\(\s*max_uses\s+is\s+null\s+or\s+use_count\s*<=\s*max_uses\s*\)/i.test(
    readSql("migrations/018_invite_use_count_guard.sql"),
  ),
  "The constraint is what protects against a future writer that forgets the CAS.",
);

// ---------------------------------------------------------------- reporting
if (failures.length > 0) {
  console.error(`\nauthority-invariants: ${failures.length} FAILED\n`);
  for (const f of failures) console.error(`  ✗ ${f}\n`);
  process.exit(1);
}
console.log("authority-invariants: all checks passed");
