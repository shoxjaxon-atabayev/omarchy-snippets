#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const store = requireFromRoot('SnippetStore.js')

assertEqual(store.blank('   '), true, 'snippets blank treats whitespace as empty')
assertEqual(store.blank('x'), false, 'snippets blank treats non-empty text as non-blank')
assertEqual(store.validName('Docker cleanup'), true, 'snippets validName accepts a real name')
assertEqual(store.validName(''), false, 'snippets validName rejects an empty name')
assertEqual(store.validContent(''), false, 'snippets validContent rejects empty content')

const existing = [
  { id: '1', name: 'Docker cleanup', content: 'docker system prune -af' },
  { id: '2', name: 'Unchanged', content: 'same' }
]

assertEqual(store.duplicateName(existing, 'Unchanged'), true, 'snippets duplicateName detects a collision')
assertEqual(store.duplicateName(existing, 'Unchanged', '2'), false, 'snippets duplicateName excludes the snippet being edited')
assertEqual(store.duplicateName(existing, 'Brand new'), false, 'snippets duplicateName allows a new name')

assertDeepEqual(
  store.displayRows(existing, 'docker'),
  [{ id: '1', name: 'Docker cleanup', preview: 'docker system prune -af' }],
  'snippets displayRows matches by content, not just name'
)
assertDeepEqual(
  store.displayRows(existing, 'unchanged'),
  [{ id: '2', name: 'Unchanged', preview: 'same' }],
  'snippets displayRows search is case-insensitive'
)
assertDeepEqual(store.displayRows(existing, 'nothing matches'), [], 'snippets displayRows returns nothing for no match')

assertEqual(
  store.contentPreview('line one\nline two\t\ttabbed'),
  'line one line two tabbed',
  'snippets contentPreview collapses whitespace onto one line'
)

assertEqual(store.nextUniqueName([], 'Docker cleanup'), 'Docker cleanup (Imported)', 'snippets nextUniqueName suffixes the first collision')
assertEqual(
  store.nextUniqueName(['Docker cleanup (Imported)'], 'Docker cleanup'),
  'Docker cleanup (Imported 2)',
  'snippets nextUniqueName numbers repeated collisions'
)
assertEqual(
  store.nextUniqueName(['Docker cleanup (Imported)', 'Docker cleanup (Imported 2)'], 'Docker cleanup'),
  'Docker cleanup (Imported 3)',
  'snippets nextUniqueName keeps counting past two collisions'
)

const imported = [
  { name: 'Docker cleanup', content: 'docker system prune -af --volumes' },
  { name: 'Unchanged', content: 'same' },
  { name: 'Brand new', content: 'echo hi' }
]
const classified = store.classifyImport(existing, imported)
assertEqual(classified.newCount, 1, 'snippets classifyImport counts genuinely new snippets')
assertDeepEqual(
  classified.conflicts,
  [{ name: 'Docker cleanup', existingContent: 'docker system prune -af', importedContent: 'docker system prune -af --volumes' }],
  'snippets classifyImport reports only differing-content collisions'
)

const dupWithinFile = store.classifyImport([], [
  { name: 'Same', content: 'a' },
  { name: 'Same', content: 'a' }
])
assertEqual(dupWithinFile.newCount, 1, 'snippets classifyImport treats an identical intra-file repeat as one new snippet')
assertEqual(dupWithinFile.conflicts.length, 0, 'snippets classifyImport does not flag an identical intra-file repeat')

const conflictWithinFile = store.classifyImport([], [
  { name: 'Same', content: 'a' },
  { name: 'Same', content: 'b' }
])
assertEqual(conflictWithinFile.newCount, 1, 'snippets classifyImport still counts the first intra-file occurrence as new')
assertEqual(conflictWithinFile.conflicts.length, 1, 'snippets classifyImport flags a differing intra-file repeat as a conflict')
JS

require_command jq
require_command wl-copy

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/bin" "$TMPDIR/home/.local/state/omarchy"

cat >"$TMPDIR/bin/wl-copy" <<'SH'
#!/bin/bash
cat >"$WL_COPY_OUT"
SH
chmod +x "$TMPDIR/bin/wl-copy"

export HOME="$TMPDIR/home"
export PATH="$TMPDIR/bin:$PATH"

save() { "$ROOT/bin/omarchy-snippets-save" <<<"$1"; }
delete() { "$ROOT/bin/omarchy-snippets-delete" "$1"; }
copy() { "$ROOT/bin/omarchy-snippets-copy" "$1"; }
snippets_store_path="$HOME/.local/state/omarchy/snippets.json"

# ---- create / update / delete -----------------------------------------

created=$(save '{"id":"","name":"Docker cleanup","content":"docker system prune -af"}')
created_id=$(jq -r '.id' <<<"$created")
[[ -n $created_id ]] || fail "snippets save assigns an id on create"
pass "snippets save assigns an id on create"

[[ $(jq -r --arg id "$created_id" '.snippets[] | select(.id == $id) | .name' "$snippets_store_path") == "Docker cleanup" ]] \
  || fail "snippets save persists the new snippet"
pass "snippets save persists the new snippet"

save '{"id":"","name":"Docker cleanup","content":"different"}' 2>/tmp/snippets-dup-err.$$ && fail "snippets save rejects a duplicate name"
grep -q 'already exists' /tmp/snippets-dup-err.$$ || fail "snippets save reports a plain-language duplicate-name error"
rm -f /tmp/snippets-dup-err.$$
pass "snippets save rejects a duplicate name"

save '{"id":"","name":"","content":"x"}' >/dev/null 2>&1 && fail "snippets save rejects an empty name"
pass "snippets save rejects an empty name"

save '{"id":"","name":"x","content":""}' >/dev/null 2>&1 && fail "snippets save rejects empty content"
pass "snippets save rejects empty content"

save "{\"id\":\"$created_id\",\"name\":\"Docker cleanup\",\"content\":\"docker system prune -af --volumes\"}" >/dev/null
updated_id=$(jq -r --arg name "Docker cleanup" '.snippets[] | select(.name == $name) | .id' "$snippets_store_path")
[[ $updated_id == "$created_id" ]] || fail "snippets save preserves id across an update"
pass "snippets save preserves id across an update"
[[ $(jq -r --arg id "$created_id" '.snippets[] | select(.id == $id) | .content' "$snippets_store_path") == "docker system prune -af --volumes" ]] \
  || fail "snippets save updates content in place"
pass "snippets save updates content in place"

control=$(save '{"id":"","name":"Control","content":"untouched"}')
control_id=$(jq -r '.id' <<<"$control")

delete "$created_id" >/dev/null
[[ $(jq '[.snippets[] | select(.id == "'"$created_id"'")] | length' "$snippets_store_path") == "0" ]] \
  || fail "snippets delete removes the targeted snippet"
pass "snippets delete removes the targeted snippet"
[[ $(jq -r --arg id "$control_id" '.snippets[] | select(.id == $id) | .content' "$snippets_store_path") == "untouched" ]] \
  || fail "snippets delete leaves other snippets untouched"
pass "snippets delete leaves other snippets untouched"

# ---- copy: exact content, no transformation ----------------------------

multiline=$(save "$(jq -cn --arg name "Multiline" --arg content "$(printf 'line one\nline two\ttabbed')" '{id:"",name:$name,content:$content}')")
multiline_id=$(jq -r '.id' <<<"$multiline")
copy_out="$TMPDIR/copied"
WL_COPY_OUT="$copy_out" copy "$multiline_id" >/dev/null
[[ $(<"$copy_out") == "$(printf 'line one\nline two\ttabbed')" ]] || fail "snippets copy sends the exact stored content to wl-copy"
pass "snippets copy sends the exact stored content to wl-copy"

# ---- export / import round trip ----------------------------------------

export_path="$TMPDIR/exported.json"
"$ROOT/bin/omarchy-snippets-export" "$export_path"
jq -e '.version == 1 and (.snippets | all(has("name") and has("content") and (has("id") | not)))' "$export_path" >/dev/null \
  || fail "snippets export strips ids and matches the interchange format"
pass "snippets export strips ids and matches the interchange format"

before_names=$(jq -c '[.snippets[].name] | sort' "$snippets_store_path")
"$ROOT/bin/omarchy-snippets-delete" "$control_id" >/dev/null
"$ROOT/bin/omarchy-snippets-delete" "$multiline_id" >/dev/null
preview=$("$ROOT/bin/omarchy-snippets-import-preview" "$export_path")
[[ $(jq -r '.newCount' <<<"$preview") == "2" ]] || fail "snippets import-preview reports every snippet as new against an emptied store"
pass "snippets import-preview reports every snippet as new against an emptied store"
"$ROOT/bin/omarchy-snippets-import-apply" "$export_path" <<<'[]' >/dev/null
after_names=$(jq -c '[.snippets[].name] | sort' "$snippets_store_path")
[[ $before_names == "$after_names" ]] || fail "snippets export/import round trip restores the same names"
pass "snippets export/import round trip restores the same names"

# ---- import conflict resolution ----------------------------------------

save '{"id":"","name":"Docker cleanup","content":"docker system prune -af"}' >/dev/null
jq -n '{version:1, snippets:[{name:"Docker cleanup", content:"docker system prune -af --volumes --force"}]}' >"$TMPDIR/conflict.json"
conflict_preview=$("$ROOT/bin/omarchy-snippets-import-preview" "$TMPDIR/conflict.json")
[[ $(jq -r '.conflicts | length' <<<"$conflict_preview") == "1" ]] || fail "snippets import-preview reports a differing-content conflict"
pass "snippets import-preview reports a differing-content conflict"

"$ROOT/bin/omarchy-snippets-import-apply" "$TMPDIR/conflict.json" <<<'[{"name":"Docker cleanup","action":"keep-both"}]' >/dev/null
jq -e '[.snippets[] | select(.name == "Docker cleanup (Imported)")] | length == 1' "$snippets_store_path" >/dev/null \
  || fail "snippets import keep-both adds a deterministically suffixed snippet"
pass "snippets import keep-both adds a deterministically suffixed snippet"
jq -e '[.snippets[] | select(.name == "Docker cleanup")] | length == 1' "$snippets_store_path" >/dev/null \
  || fail "snippets import keep-both leaves the original snippet untouched"
pass "snippets import keep-both leaves the original snippet untouched"

# ---- invalid import leaves the store untouched --------------------------

before_hash=$(sha256sum "$snippets_store_path")
echo "not json" >"$TMPDIR/bad.json"
"$ROOT/bin/omarchy-snippets-import-preview" "$TMPDIR/bad.json" >/dev/null 2>&1 && fail "snippets import-preview rejects invalid JSON"
"$ROOT/bin/omarchy-snippets-import-apply" "$TMPDIR/bad.json" <<<'[]' >/dev/null 2>"$TMPDIR/bad-apply.err" && fail "snippets import-apply rejects invalid JSON"
grep -q 'Invalid snippet file' "$TMPDIR/bad-apply.err" || fail "snippets import-apply rejects invalid JSON for the right reason" "$(<"$TMPDIR/bad-apply.err")"
after_hash=$(sha256sum "$snippets_store_path")
[[ $before_hash == "$after_hash" ]] || fail "snippets store is byte-identical after a rejected import"
pass "snippets store is byte-identical after a rejected import"

echo '{"version":2,"snippets":[]}' >"$TMPDIR/badversion.json"
"$ROOT/bin/omarchy-snippets-import-preview" "$TMPDIR/badversion.json" 2>/tmp/snippets-ver-err.$$ && fail "snippets import-preview rejects an unsupported version"
grep -q 'Unsupported snippet format version' /tmp/snippets-ver-err.$$ || fail "snippets import-preview names the unsupported-version error"
rm -f /tmp/snippets-ver-err.$$
pass "snippets import-preview rejects an unsupported version"

# ---- large import completes as one write --------------------------------

node -e '
const items = []
for (let i = 0; i < 1500; i++) items.push({ name: "bulk " + i, content: "content " + i })
console.log(JSON.stringify({ version: 1, snippets: items }))
' >"$TMPDIR/large.json"
"$ROOT/bin/omarchy-snippets-import-apply" "$TMPDIR/large.json" <<<'[]' >/dev/null
[[ $(jq '[.snippets[] | select(.name | startswith("bulk "))] | length' "$snippets_store_path") == "1500" ]] \
  || fail "snippets import-apply completes a 1500-snippet import as one write"
pass "snippets import-apply completes a 1500-snippet import as one write"

# ---- storage permissions -------------------------------------------------

perm=$(stat -c %a "$snippets_store_path")
[[ $perm == "600" ]] || fail "snippets store is not readable by other users" "mode: $perm"
pass "snippets store is not readable by other users"

# ---- no network tooling anywhere in the CLI -----------------------------

if grep -lE '\b(curl|wget)\b' "$ROOT"/bin/omarchy-snippets-* >/dev/null 2>&1; then
  fail "snippets CLI scripts do not reference any network tool"
fi
pass "snippets CLI scripts do not reference any network tool"

# ---- arbitrary/adversarial snippet names round-trip safely --------------
# Regression coverage for JS prototype-chain hazards: a snippet literally
# named "__proto__" (or "constructor") must behave like any other name, not
# silently resolve through Object.prototype when used as a lookup key.

save '{"id":"","name":"__proto__","content":"proto content"}' >/dev/null
[[ $(jq -r '[.snippets[] | select(.name == "__proto__")] | length' "$snippets_store_path") == "1" ]] \
  || fail "snippets save persists a snippet literally named __proto__"
pass "snippets save persists a snippet literally named __proto__"

proto_out="$TMPDIR/proto-copied"
proto_id=$(jq -r '.snippets[] | select(.name == "__proto__") | .id' "$snippets_store_path")
WL_COPY_OUT="$proto_out" copy "$proto_id" >/dev/null
[[ $(<"$proto_out") == "proto content" ]] || fail "snippets copy handles a __proto__-named snippet like any other"
pass "snippets copy handles a __proto__-named snippet like any other"

"$ROOT/bin/omarchy-snippets-delete" "$proto_id" >/dev/null
[[ $(jq '[.snippets[] | select(.name == "__proto__")] | length' "$snippets_store_path") == "0" ]] \
  || fail "snippets delete removes a __proto__-named snippet"
pass "snippets delete removes a __proto__-named snippet"

# ---- store read hardening -------------------------------------------------
# Regression coverage for the security-review finding: snippets.json lives
# at a predictable path, so a planted symlink, FIFO, or oversized regular
# file there must be rejected by omarchy-snippets-read (and, through it,
# every CLI helper's snippets_load) rather than followed, blocked on, or
# read unbounded. Uses its own HOME so these fixtures never touch the store
# the tests above already exercised.

READ_HOME=$(mktemp -d)
trap 'rm -rf "$TMPDIR" "$READ_HOME"' EXIT
mkdir -p "$READ_HOME/.local/state/omarchy"
read_store_path="$READ_HOME/.local/state/omarchy/snippets.json"

read_store() { HOME="$READ_HOME" "$ROOT/bin/omarchy-snippets-read"; }

rm -f "$read_store_path"
[[ $(read_store) == '{"version":1,"snippets":[]}' ]] \
  || fail "snippets read returns the empty-store default when the file is missing"
pass "snippets read returns the empty-store default when the file is missing"

echo '{"version":1,"snippets":[{"id":"1","name":"a","content":"b"}]}' >"$read_store_path"
[[ $(read_store) == '{"version":1,"snippets":[{"id":"1","name":"a","content":"b"}]}' ]] \
  || fail "snippets read returns valid bounded JSON unchanged"
pass "snippets read returns valid bounded JSON unchanged"

echo 'not json' >"$read_store_path"
read_store >/dev/null 2>&1 && fail "snippets read rejects malformed JSON"
pass "snippets read rejects malformed JSON"

rm -f "$read_store_path"
ln -s /etc/passwd "$read_store_path"
read_store >/dev/null 2>&1 && fail "snippets read refuses to follow a symlinked store"
pass "snippets read refuses to follow a symlinked store"

rm -f "$read_store_path"
mkfifo "$read_store_path"
set +e
timeout 5 env HOME="$READ_HOME" "$ROOT/bin/omarchy-snippets-read" >/dev/null 2>&1
fifo_status=$?
set -e
rm -f "$read_store_path"
((fifo_status != 124)) || fail "snippets read must not block on a FIFO store" "read hung and was killed by timeout"
((fifo_status != 0)) || fail "snippets read rejects a FIFO store"
pass "snippets read rejects a FIFO store without blocking"

node -e '
process.stdout.write(JSON.stringify({ version: 1, snippets: [{ id: "1", name: "big", content: "x".repeat(11 * 1024 * 1024) }] }))
' >"$read_store_path"
read_store >/dev/null 2>&1 && fail "snippets read rejects an oversized store"
pass "snippets read rejects an oversized store"
rm -f "$read_store_path"

echo '{"version":1,"snippets":[]}' >"$read_store_path"
if chown 65534 "$read_store_path" 2>/dev/null; then
  read_store >/dev/null 2>&1 && fail "snippets read rejects a store owned by another user"
  pass "snippets read rejects a store owned by another user"
else
  pass "wrong-owner store not testable without chown privilege; skipping"
fi
rm -f "$read_store_path"

# CLI wiring: a hostile store must fail the whole command, not just the read.
ln -s /etc/passwd "$read_store_path"
HOME="$READ_HOME" "$ROOT/bin/omarchy-snippets-copy" "anything" >/dev/null 2>/tmp/snippets-symlink-err.$$ \
  && fail "snippets CLI refuses to operate against a symlinked store"
grep -q 'Could not read snippet store' /tmp/snippets-symlink-err.$$ \
  || fail "snippets CLI surfaces a clear error for a hostile store"
rm -f /tmp/snippets-symlink-err.$$ "$read_store_path"
pass "snippets CLI refuses to operate against a symlinked store"

# ---- import file read hardening -------------------------------------------
# Regression coverage for the security-review finding: the user-selected
# import file is opened exactly once by omarchy-snippets-import-read
# (no-follow, nonblocking) and bounded (size, record count, field lengths)
# before omarchy-snippets-import-preview/-import-apply ever see it, rather
# than being reopened by path repeatedly with unrestricted jq reads.

IMPORT_DIR="$TMPDIR/import-fixtures"
mkdir -p "$IMPORT_DIR"
import_read() { "$ROOT/bin/omarchy-snippets-import-read" "$1"; }

echo '{"version":1,"snippets":[{"name":"a","content":"b"}]}' >"$IMPORT_DIR/valid.json"
[[ $(import_read "$IMPORT_DIR/valid.json") == '{"version": 1, "snippets": [{"name": "a", "content": "b"}]}' ]] \
  || fail "snippets import-read returns the validated document for a valid file"
pass "snippets import-read returns the validated document for a valid file"

ln -s /etc/passwd "$IMPORT_DIR/symlink.json"
import_read "$IMPORT_DIR/symlink.json" >/dev/null 2>&1 && fail "snippets import-read refuses to follow a symlinked import file"
pass "snippets import-read refuses to follow a symlinked import file"

mkfifo "$IMPORT_DIR/fifo.json"
set +e
timeout 5 "$ROOT/bin/omarchy-snippets-import-read" "$IMPORT_DIR/fifo.json" >/dev/null 2>&1
import_fifo_status=$?
set -e
rm -f "$IMPORT_DIR/fifo.json"
((import_fifo_status != 124)) || fail "snippets import-read must not block on a FIFO import file" "read hung and was killed by timeout"
((import_fifo_status != 0)) || fail "snippets import-read rejects a FIFO import file"
pass "snippets import-read rejects a FIFO import file without blocking"

node -e '
process.stdout.write(JSON.stringify({ version: 1, snippets: [{ name: "big", content: "x".repeat(11 * 1024 * 1024) }] }))
' >"$IMPORT_DIR/oversized.json"
import_read "$IMPORT_DIR/oversized.json" >/dev/null 2>/tmp/snippets-import-oversized-err.$$ && fail "snippets import-read rejects an oversized import file"
grep -q 'too large' /tmp/snippets-import-oversized-err.$$ || fail "snippets import-read names the too-large error"
rm -f /tmp/snippets-import-oversized-err.$$
pass "snippets import-read rejects an oversized import file"

echo 'not json' >"$IMPORT_DIR/malformed.json"
import_read "$IMPORT_DIR/malformed.json" >/dev/null 2>&1 && fail "snippets import-read rejects malformed JSON"
pass "snippets import-read rejects malformed JSON"

echo '{"foo":"bar"}' >"$IMPORT_DIR/wrongshape.json"
import_read "$IMPORT_DIR/wrongshape.json" >/dev/null 2>&1 && fail "snippets import-read rejects the wrong JSON shape"
pass "snippets import-read rejects the wrong JSON shape"

node -e '
const items = []
for (let i = 0; i < 5001; i++) items.push({ name: "n" + i, content: "c" + i })
process.stdout.write(JSON.stringify({ version: 1, snippets: items }))
' >"$IMPORT_DIR/toomany.json"
import_read "$IMPORT_DIR/toomany.json" >/dev/null 2>/tmp/snippets-import-toomany-err.$$ && fail "snippets import-read rejects too many records"
grep -q 'too many snippets' /tmp/snippets-import-toomany-err.$$ || fail "snippets import-read names the too-many-records error"
rm -f /tmp/snippets-import-toomany-err.$$
pass "snippets import-read rejects too many records"

node -e '
process.stdout.write(JSON.stringify({ version: 1, snippets: [{ name: "n".repeat(201), content: "c" }] }))
' >"$IMPORT_DIR/longname.json"
import_read "$IMPORT_DIR/longname.json" >/dev/null 2>/tmp/snippets-import-longname-err.$$ && fail "snippets import-read rejects an excessively long name"
grep -q 'name is too long' /tmp/snippets-import-longname-err.$$ || fail "snippets import-read names the name-too-long error"
rm -f /tmp/snippets-import-longname-err.$$
pass "snippets import-read rejects an excessively long name"

node -e '
process.stdout.write(JSON.stringify({ version: 1, snippets: [{ name: "n", content: "c".repeat(100001) }] }))
' >"$IMPORT_DIR/longcontent.json"
import_read "$IMPORT_DIR/longcontent.json" >/dev/null 2>/tmp/snippets-import-longcontent-err.$$ && fail "snippets import-read rejects excessively long content"
grep -q 'content is too long' /tmp/snippets-import-longcontent-err.$$ || fail "snippets import-read names the content-too-long error"
rm -f /tmp/snippets-import-longcontent-err.$$
pass "snippets import-read rejects excessively long content"

# Pathname replacement / TOCTOU: what's at the path when the CLI opens it,
# not what was there when it was selected, is what must be validated. This
# can't spawn a real concurrent racer safely in a test, but it does prove
# the file is evaluated at the single open() import-read performs, not at
# some earlier check -- a plain file is swapped for a symlink before the
# only read happens, and that read must still reject it.
echo '{"version":1,"snippets":[{"name":"race","content":"x"}]}' >"$IMPORT_DIR/race.json"
rm -f "$IMPORT_DIR/race.json"
ln -s /etc/shadow "$IMPORT_DIR/race.json"
import_read "$IMPORT_DIR/race.json" >/dev/null 2>&1 && fail "snippets import-read rejects a path swapped to a symlink before the single read"
pass "snippets import-read rejects a path swapped to a symlink before the single read"

# CLI wiring: import-preview and import-apply must fail through the same
# hardened reader too, not just omarchy-snippets-import-read directly.
"$ROOT/bin/omarchy-snippets-import-preview" "$IMPORT_DIR/race.json" >/dev/null 2>&1 \
  && fail "snippets import-preview refuses a symlinked import file"
pass "snippets import-preview refuses a symlinked import file"
"$ROOT/bin/omarchy-snippets-import-apply" "$IMPORT_DIR/race.json" <<<'[]' >/dev/null 2>"$IMPORT_DIR/race-apply.err" \
  && fail "snippets import-apply refuses a symlinked import file"
grep -q 'Invalid snippet file' "$IMPORT_DIR/race-apply.err" \
  || fail "snippets import-apply refuses a symlinked import file through the hardened reader" "$(<"$IMPORT_DIR/race-apply.err")"
pass "snippets import-apply refuses a symlinked import file"

rm -rf "$IMPORT_DIR"

# ---- snippet data never travels on a process command line -----------------
# Regression coverage for the marketplace security finding: any local user
# can read another process's argv through /proc/<pid>/cmdline, so snippet
# names, content, and import resolutions must reach the CLI and every
# process it spawns over stdin or pipes, never as arguments. PATH is
# narrowed to logging wrappers around exactly the external commands the CLI
# uses, so every exec it makes is recorded -- and a command without a
# wrapper fails loudly instead of slipping past the log. (The python
# helpers are exec'd through an absolute shebang; their argv is just their
# own path, plus the import file path for import-read.)

ARGV_DIR="$TMPDIR/argv"
ARGV_SHIMS="$ARGV_DIR/shims"
ARGV_HOME="$ARGV_DIR/home"
ARGV_LOG="$ARGV_DIR/argv.log"
mkdir -p "$ARGV_SHIMS" "$ARGV_HOME/.local/state/omarchy"
: >"$ARGV_LOG"

for cmd in cat chmod dirname jq mkdir mktemp mv readlink seq wl-copy; do
  real=$(type -P "$cmd") || fail "argv check can resolve $cmd"
  cat >"$ARGV_SHIMS/$cmd" <<SH
#!/bin/bash
printf '%s\\0' "\$0" "\$@" >>"\$ARGV_LOG"
exec $(printf '%q' "$real") "\$@"
SH
  chmod +x "$ARGV_SHIMS/$cmd"
done

argv_cli() {
  PATH="$ARGV_SHIMS" HOME="$ARGV_HOME" ARGV_LOG="$ARGV_LOG" WL_COPY_OUT="$ARGV_DIR/copied" "$@"
}
argv_store="$ARGV_HOME/.local/state/omarchy/snippets.json"
marker="argv-canary-$$-$RANDOM"
secret_name="Prod token $marker"
secret_content=$(printf 'export TOKEN=%s\n  "quoted" \\ back\tslash ключ🔑' "$marker")

# Control: prove the log would catch a leak before trusting a clean one.
argv_cli jq -n --arg leak "$marker" '$leak' >/dev/null
grep -a -q -F -- "$marker" "$ARGV_LOG" || fail "argv log records a value passed as an argument"
: >"$ARGV_LOG"
pass "argv log records a value passed as an argument"

create_payload=$(jq -cn --arg name "$secret_name" --arg content "$secret_content" '{id: "", name: $name, content: $content}')
created=$(argv_cli "$ROOT/bin/omarchy-snippets-save" <<<"$create_payload")
secret_id=$(jq -r '.id' <<<"$created")
[[ $(jq -r '.content' <<<"$created") == "$secret_content" ]] || fail "snippets save over stdin reports the saved content"
argv_cli "$ROOT/bin/omarchy-snippets-save" <<<"$create_payload" >/dev/null 2>"$ARGV_DIR/dup.err" \
  && fail "snippets save over stdin still rejects a duplicate name"
grep -q -F "A snippet named \"$secret_name\" already exists." "$ARGV_DIR/dup.err" \
  || fail "snippets save over stdin still names the duplicate"

secret_content="$secret_content (rotated)"
update_payload=$(jq -cn --arg id "$secret_id" --arg name "$secret_name" --arg content "$secret_content" '{id: $id, name: $name, content: $content}')
argv_cli "$ROOT/bin/omarchy-snippets-save" <<<"$update_payload" >/dev/null
[[ $(jq -r --arg id "$secret_id" '.snippets[] | select(.id == $id) | .content' "$argv_store") == "$secret_content" ]] \
  || fail "snippets save over stdin updates content in place"

argv_cli "$ROOT/bin/omarchy-snippets-copy" "$secret_id" >/dev/null
[[ $(<"$ARGV_DIR/copied") == "$secret_content" ]] || fail "snippets copy still sends the exact stored content"

argv_cli "$ROOT/bin/omarchy-snippets-export" "$ARGV_DIR/exported.json"
jq -e --arg name "$secret_name" '[.snippets[] | select(.name == $name)] | length == 1' "$ARGV_DIR/exported.json" >/dev/null \
  || fail "snippets export still writes the stored snippet"

jq -n --arg name "$secret_name" --arg marker "$marker" \
  '{version: 1, snippets: [{name: $name, content: ("imported " + $marker)}, {name: ("New " + $marker), content: $marker}]}' \
  >"$ARGV_DIR/import.json"
argv_preview=$(argv_cli "$ROOT/bin/omarchy-snippets-import-preview" "$ARGV_DIR/import.json")
jq -e --arg name "$secret_name" '.newCount == 1 and (.conflicts | length == 1 and .[0].name == $name)' <<<"$argv_preview" >/dev/null \
  || fail "snippets import-preview still reports conflicts and new snippets"
resolutions=$(jq -cn --arg name "$secret_name" '[{name: $name, action: "keep-both"}]')
argv_cli "$ROOT/bin/omarchy-snippets-import-apply" "$ARGV_DIR/import.json" <<<"$resolutions" >/dev/null
jq -e --arg name "$secret_name (Imported)" --arg marker "$marker" \
  '[.snippets[] | select(.name == $name and .content == ("imported " + $marker))] | length == 1' "$argv_store" >/dev/null \
  || fail "snippets import-apply honors resolutions read from stdin"

argv_cli "$ROOT/bin/omarchy-snippets-delete" "$secret_id" >/dev/null

grep -a -q -F -- '--rawfile' "$ARGV_LOG" && grep -a -q -F -- '--slurpfile' "$ARGV_LOG" \
  || fail "argv log captured the CLI's jq calls"
if grep -a -q -F -- "$marker" "$ARGV_LOG"; then
  fail "no snippet name, content, or resolution appears in any process argv" \
    "$(tr '\0' ' ' <"$ARGV_LOG" | grep -a -F -- "$marker" | head -c 400)"
fi
pass "no snippet name, content, or resolution appears in any process argv"

# The old argument forms must fail loudly, not hang or quietly accept a
# payload on argv again.
before_hash=$(sha256sum "$argv_store")
"$ROOT/bin/omarchy-snippets-save" '{"id":"","name":"argv","content":"argv"}' </dev/null >/dev/null 2>"$ARGV_DIR/save-arg.err" \
  && fail "snippets save refuses a payload passed as an argument"
grep -q 'Could not save snippet' "$ARGV_DIR/save-arg.err" || fail "snippets save names the refused argument form"
HOME="$ARGV_HOME" "$ROOT/bin/omarchy-snippets-import-apply" "$ARGV_DIR/import.json" '[]' </dev/null >/dev/null 2>"$ARGV_DIR/apply-arg.err" \
  && fail "snippets import-apply refuses resolutions passed as an argument"
grep -q 'Could not import snippets' "$ARGV_DIR/apply-arg.err" || fail "snippets import-apply names the refused argument form"
HOME="$ARGV_HOME" "$ROOT/bin/omarchy-snippets-import-apply" "$ARGV_DIR/import.json" <<<'[] []' >/dev/null 2>&1 \
  && fail "snippets import-apply rejects more than one resolutions document"
[[ $(sha256sum "$argv_store") == "$before_hash" ]] || fail "refused argument forms leave the store untouched"
pass "old argument forms are refused and leave the store untouched"

HOME="$ARGV_HOME" "$ROOT/bin/omarchy-snippets-import-apply" "$ARGV_DIR/import.json" </dev/null >/dev/null
jq -e --arg marker "$marker" '[.snippets[] | select(.name == ("New " + $marker))] | length == 1' "$argv_store" >/dev/null \
  || fail "snippets import-apply treats empty stdin as no resolutions"
pass "snippets import-apply treats empty stdin as no resolutions"

# ---- payloads larger than one argv string --------------------------------
# Linux caps a single argv string at 128 KiB (MAX_ARG_STRLEN), so the old
# argument-based transport could not save a snippet this large or import
# once the store outgrew that size. Multibyte text also spans jq's 4 KiB
# --rawfile read chunks many times over.

node -e '
let s = "  leading spaces, \"quotes\", \\backslash\\, tab\t, ключ🔑 é\n"
while (Buffer.byteLength(s) < 200000) s += "строка " + s.length + " 🔑 \"q\" \\ \t\n"
process.stdout.write(s + "end")
' >"$ARGV_DIR/large-content"
large_content=$(<"$ARGV_DIR/large-content")
large_payload=$(jq -cn --rawfile content "$ARGV_DIR/large-content" '{id: "", name: "Large", content: $content}')
large=$(HOME="$ARGV_HOME" "$ROOT/bin/omarchy-snippets-save" <<<"$large_payload")
large_id=$(jq -r '.id' <<<"$large")
HOME="$ARGV_HOME" WL_COPY_OUT="$ARGV_DIR/large-copied" "$ROOT/bin/omarchy-snippets-copy" "$large_id" >/dev/null
cmp -s "$ARGV_DIR/large-content" "$ARGV_DIR/large-copied" \
  || fail "snippets save and copy keep a 200 KB multibyte snippet byte-for-byte"
pass "snippets save and copy keep a 200 KB multibyte snippet byte-for-byte"

(( $(stat -c %s "$argv_store") > 131072 )) || fail "large-store fixture exceeds 128 KiB"
jq -n '{version: 1, snippets: [{name: "After large", content: "x"}]}' >"$ARGV_DIR/after-large.json"
HOME="$ARGV_HOME" "$ROOT/bin/omarchy-snippets-import-preview" "$ARGV_DIR/after-large.json" >/dev/null \
  || fail "snippets import-preview works with a store larger than 128 KiB"
HOME="$ARGV_HOME" "$ROOT/bin/omarchy-snippets-import-apply" "$ARGV_DIR/after-large.json" <<<'[]' >/dev/null \
  || fail "snippets import-apply works with a store larger than 128 KiB"
jq -e '[.snippets[] | select(.name == "After large")] | length == 1' "$argv_store" >/dev/null \
  || fail "snippets import-apply adds snippets to a store larger than 128 KiB"
[[ $(jq -r --arg id "$large_id" '.snippets[] | select(.id == $id) | .content' "$argv_store") == "$large_content" ]] \
  || fail "snippets import-apply leaves a large existing snippet intact"
pass "snippets import works with a store larger than 128 KiB"

# ---- Panel.qml hands payloads over stdin, not argv -------------------------
# The QML side can't run here, so guard its wiring statically: no Process
# command list may carry the save payload, form fields, or resolutions, and
# both stdin-fed processes must actually write their payload.

if grep -nE '(command[[:space:]]*[:=][[:space:]]*\[).*(JSON\.stringify|[Pp]ayload|formName|formContent|resolutions)' "$ROOT/Panel.qml"; then
  fail "Panel.qml never puts a snippet payload in a Process command"
fi
grep -q 'saveProc.write(saveProc.stdinPayload' "$ROOT/Panel.qml" \
  && grep -q 'importApplyProc.write(importApplyProc.stdinPayload' "$ROOT/Panel.qml" \
  || fail "Panel.qml writes the save payload and resolutions to stdin"
pass "Panel.qml never puts a snippet payload in a Process command"

# The copy notification's text is an argument to omarchy-notification-send,
# so it must be the fixed "Copied", never the snippet's name: no
# notification call may reference a name or content value, and the copy
# path must not carry the name at all.
grep -qF 'Quickshell.execDetached(["omarchy-notification-send", "Copied", "-t", "1500"])' "$ROOT/Panel.qml" \
  || fail "Panel.qml copy notification is the fixed text \"Copied\""
if grep -nE 'execDetached\(.*([Nn]ame|[Cc]ontent)' "$ROOT/Panel.qml"; then
  fail "Panel.qml notifications never pass a snippet name or content as an argument"
fi
if grep -nE 'pendingName|copySnippet\([^)]*,' "$ROOT/Panel.qml"; then
  fail "Panel.qml copy path does not carry the snippet name"
fi
pass "Panel.qml copy notification does not include the snippet name in its arguments"
