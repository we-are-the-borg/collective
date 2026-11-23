#!/usr/bin/env bash
# Tests for scripts/public-check.sh, run against a copy of it and its allow
# file in a throwaway repo with findings and allowed cases per rule. Every
# name, address and token below is invented, the login and host name too:
# stubs for `id` and `hostname` stand in for this machine's, so that the
# result does not depend on who runs the tests (a CI login is generic).
#
#   scripts/test-public-check.sh
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
readonly SCRIPTS TMP
trap 'rm -rf "$TMP"' EXIT

failures=0
current=""

fail() {
  echo "FAIL  $current: $*"
  failures=$((failures + 1))
}

pass() {
  echo "ok    $current"
}

# Runs the check with "$@", leaving its output in $out and its exit code in
# $code.
run() {
  code=0
  out="$("$@" 2>&1)" || code=$?
}

expect_code() {
  [[ $code -eq $1 ]] || fail "exit $code, expected $1"$'\n'"$out"
}

expect_line() {
  grep -qxF -- "$1" <<<"$out" || fail "missing line: $1"$'\n'"$out"
}

expect_prefix() {
  grep -qF -- "$1" <<<"$out" || fail "missing: $1"$'\n'"$out"
}

expect_absent() {
  if grep -qF -- "$1" <<<"$out"; then
    fail "unexpected: $1"$'\n'"$out"
  fi
}

# Strings the check looks for, built from halves so that this file passes
# the check itself. The identity in the throwaway repo is invented, and so
# are the login and host name, which the stubs below print.
users="Us"
users="${users}ers"
home="ho"
home="${home}me"
owner="grm"
owner="${owner}lin"
dev="DE"
dev="${dev}V"
hash="#"
dcn="deci"
dcn="${dcn}sion"
ent="Entschei"
ent="${ent}dung"
planning="task"
planning="${planning}s"
at="@"
# Prefix letters of design item ids; with a digit right after them in this
# file they would be findings.
a="A" f="F" g="G" h="H" n="N" o="O" r="R" s="S" u="U"
login="qwaldo"
host="vexbox"
readonly users home owner dev hash dcn ent planning at a f g h n o r s u login host

# Stubs for `id` and `hostname`, which print what PC_STUB_LOGIN and
# PC_STUB_HOST say, first in PATH for every run of the check.
stubs="$TMP/stubs"
mkdir -p "$stubs"
cat >"$stubs/id" <<'EOF'
#!/bin/sh
echo "$PC_STUB_LOGIN"
EOF
cat >"$stubs/hostname" <<'EOF'
#!/bin/sh
echo "$PC_STUB_HOST"
EOF
chmod +x "$stubs/id" "$stubs/hostname"
export PATH="$stubs:$PATH" PC_STUB_LOGIN="$login" PC_STUB_HOST="$host"

# A repo with the checker in scripts/, findings and allowed cases for every
# rule, a planning folder and an untracked file.
make_repo() {
  local dir="$TMP/repo"
  mkdir -p "$dir/scripts" "$dir/src" "$dir/$planning" "$dir/Tests/Fixtures/run"
  cp "$SCRIPTS/public-check.sh" "$SCRIPTS/public-check.allow" "$dir/scripts/"
  (
    cd "$dir"
    git init --quiet --initial-branch=main
    git config user.name "Jane Roe"
    git config user.email "jroe${at}roe-mail.io"
    # An older address of the same name, which the identity rule reads
    # from the history.
    git commit --quiet --allow-empty -m start --author="Jane Roe <jane.roe${at}old-mail.io>"
  )

  cat >"$dir/src/paths.txt" <<EOF
home: /$users/jdoe/projects
scrubbed: /$users/user/dev
escaped: "\/$users\/jdoe\/x"
encoded: -$users-user-dev-x
config in ~/$dev/collective and \$HOME/$dev/x
project: -$users-jdoe-dev-x
quoted: "-$users-jdoe"
slash: -$users-jdoe/x
at the end: -$users-jdoe
scrubbed quoted: "-$users-user"
double-escaped: "\\\\/$users\\\\/jdoe\\\\/x"
double-escaped scrubbed: "\\\\/$users\\\\/user\\\\/x"
url: https://github.com/tinted-theming/$home/blob/main/x
linux: /$home/jdoe/x
url users: https://example.com/All-$users/guide
escaped scrubbed linux: "\/$home\/user"
after an escaped newline: "x\n/$users/jdoe/x"
scrubbed after an escaped newline: "x\n/$users/user"
EOF

  cat >"$dir/src/repo.swift" <<EOF
let bundle = "de.$owner.Collective.updates"
// See $owner/agent-collective for the old home.
// Run /$owner:ticket 12 to start.
EOF

  cat >"$dir/src/plan.md" <<EOF
## Heading 2
Fixed in ${hash}42, see there.
As decided in $dcn 12.
Depends on we-are-the-borg/subspace${hash}14 and subspace${hash}7.
#Preview("Card") { }
#if os(macOS)
let a = #available(macOS 15, *)
color: ${hash}1e1e2e; border: ${hash}fff; tint: ${hash}000
[FAQ](${hash}what-if-i-dont-see-any-sessions)
Planned in $planning/todo.md.
Wie in $ent 7 festgelegt.
See https://example.com/page${hash}3, README.md${hash}12 and docs/guide.html${hash}4.
<rect fill="${hash}333" stroke=${hash}444 style="color: ${hash}555"/>
background-color:${hash}1234;
Also ${hash}50/${hash}54 and (${hash}128).
title == "${hash}128 C"
let grey = "${hash}333"
Only we-are-the-borg/subspace${hash}14 and wtb/subspace${hash}8.
"prompt": "[Image ${hash}1]"
"prompt": "[Image ${hash}2] after ${hash}43"
EOF

  cat >"$dir/src/style.css" <<EOF
.a { outline: 1px solid ${hash}333; }
EOF

  cat >"$dir/src/mail.txt" <<EOF
Contact jdoe${at}acme-mail.io for access.
Placeholder: user${at}example.org
icon_16x16${at}2x.png
EOF

  cat >"$dir/src/people.txt" <<EOF
Reviewed by Jane.
Mail jroe${at}roe-mail.io
Seen on roe-mail.io
Janet and Roebuck are other people.
Domain: old-mail.io
Login $login
Host $host
home: /$users/$login/x
Extra: zorblax here
profile: github.com/users/jroe
encoded lower case: -users-jroe-x
shouted: /USERS/jroe
myhome/jroe
double-escaped home: "\\\\/$users\\\\/$login\\\\/x"
after an escaped newline: "x\n/$users/$login/x"
Generic: user on dev
CI: the runner starts
EOF

  # A long line whose snippet is cut inside multi-byte characters.
  local arrows="↩↩↩↩↩"
  arrows="$arrows$arrows$arrows$arrows$arrows"
  printf '%s %s42 %s\n' "$arrows" "$hash" "$arrows" >"$dir/src/long.txt"

  cat >"$dir/THIRD_PARTY_NOTICES.md" <<EOF
Copyright (c) Max Muster <mm${at}acme-mail.io>
EOF

  # The repo's own license is checked, third-party ones are not.
  mkdir -p "$dir/vendor/lib"
  echo "Copyright (c) Jo Public <jo${at}public-mail.io>" >"$dir/LICENSE"
  echo "Copyright (c) Max Muster <mm${at}acme-mail.io>" >"$dir/LICENSE-icons"
  echo "Copyright (c) Max Muster <mm${at}acme-mail.io>" >"$dir/vendor/lib/LICENSE"

  printf '%s\n' \
    '{"session_id":"1b4e28ba-2fa1-11d2-883f-0016d3cca427","accountUuid":"7c9e6679-7425-40de-944b-e07fc1f90ae7"}' \
    '{"creator_account_id":"00000000-0000-0000-0000-000000000000","creator_user_id":"user-REDACTED"}' \
    '{"token":"sk-ant-api03-abcdefghijklmnop"}' \
    "-rw-r--r--  1 $login  staff  42 notes.txt" \
    "{\"host\":\"$host\"}" \
    '{"user_id": 12345}' \
    '{"account_id":987}' \
    '{"user_id":0}' \
    >"$dir/Tests/Fixtures/run/event.json"

  # Design item ids in their contexts, then tokens that only look like one.
  cat >"$dir/src/design.swift" <<EOF
/// Falls back by itself (${h}28).
/// One stop for both lists (${h}14, ${o}4).
/// Pick one (${f}23/${f}29) here.
/// Rules ${h}17–${h}20 apply.
/// Rules ${h}17-${h}20 apply.
/// As in design ${h}14 and on the board.
/// As drawn on board ${f}3.
/// See $dcn 81 ${g}13.
/// The line under the box (restyle.md, ${f}11).
/// Its link (${f}24 B).
/// The error rows (${o}6 for Match).
#Preview("${r}2-01 · done") { }
/// ${u}3: an ended session stays unread.
/// ${s}3, ${n}3: the bundle is installed.
/// The first variant (${u}1a).
/// The form without a target (${s}6).
/// Press ${f}1 for help, the ${f}1 key or (${f}1 key).
## ${h}1 heading, an ${h}1 or <${h}1>
let ellipsis = "${u}+2026", key = "base0A", mask = 0xA1F2
#if os(macOS)
let version = "1.2.0-${r}1", build = "(${a}12.0)"
toolStart(call: "${u}1"); let calls = ["${u}1", "${u}2"]
/// ${s}17 ends; ${s}4 asks (024) and later (${r}4-006).
let nbsp = "\u{A0}", path = "M15 0 ${h}16.5 a5.5"
/// Capture runs as subspace names them: (${s}16) and (${s}6a).
EOF
  printf '%s\n' "{\"note\":\"(${h}28)\"}" >"$dir/Tests/Fixtures/run/notes.json"

  # Outside Fixtures/ the fixtures rule does not apply.
  cat >"$dir/src/session.swift" <<'EOF'
let session = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
let json = #"{"accountUuid":"7c9e6679-7425-40de-944b-e07fc1f90ae7","key":"sk-ant-api03-abcdefghijklmnop"}"#
EOF

  cat >"$dir/$planning/todo.md" <<EOF
- [ ] ${hash}12 in /$users/jdoe, $dcn 3, jdoe${at}acme-mail.io, Jane
EOF

  (
    cd "$dir"
    git add .
    git commit --quiet -m init
  )
  # Untracked, so never read.
  echo "/$users/jdoe and ${hash}99" >"$dir/AGENTS.md"
  echo "$dir"
}

REPO="$(make_repo)"
readonly REPO
readonly CHECK="$REPO/scripts/public-check.sh"

current="reports each finding with path, line and rule"
before=$failures
run "$CHECK"
expect_code 1
expect_line "src/paths.txt:1: [paths] home: /$users/jdoe/projects"
expect_prefix "src/paths.txt:3: [paths] "
expect_prefix "src/repo.swift:2: [private-repo] "
expect_prefix "src/plan.md:2: [plan-refs] "
expect_prefix "src/plan.md:3: [plan-refs] "
expect_prefix "src/plan.md:10: [plan-refs] "
expect_prefix "src/mail.txt:1: [addresses] "
expect_prefix "src/people.txt:1: [identity] "
expect_prefix "Tests/Fixtures/run/event.json:1: [fixtures] "
expect_prefix "Tests/Fixtures/run/event.json:3: [fixtures] "
[[ $failures -eq $before ]] && pass

current="counts per rule and in total"
before=$failures
expect_line "paths          12"
expect_line "private-repo   2"
expect_line "plan-refs      10"
expect_line "design-ids     16"
expect_line "addresses      3"
expect_line "identity       12"
expect_line "fixtures       4"
expect_line "total          59"
[[ $failures -eq $before ]] && pass

current="allowed cases do not count"
before=$failures
expect_absent "src/paths.txt:2:"
expect_absent "src/paths.txt:4:"
expect_absent "src/paths.txt:10:"
expect_absent "src/paths.txt:12:"
expect_absent "src/repo.swift:1:"
expect_absent "src/mail.txt:2:"
expect_absent "src/mail.txt:3:"
expect_absent "THIRD_PARTY_NOTICES.md"
expect_absent "Tests/Fixtures/run/event.json:2:"
expect_absent "Tests/Fixtures/run/event.json:8:"
[[ $failures -eq $before ]] && pass

current="a folder under the home names nobody"
before=$failures
expect_absent "src/paths.txt:5:"
[[ $failures -eq $before ]] && pass

current="encoded home names end at a dash, quote, slash or the line end"
before=$failures
for line in 6 7 8 9; do
  expect_prefix "src/paths.txt:$line: [paths] "
done
[[ $failures -eq $before ]] && pass

current="home paths count only where a path starts"
before=$failures
expect_absent "src/paths.txt:13:"
expect_prefix "src/paths.txt:14: [paths] "
expect_absent "src/paths.txt:15:"
expect_absent "src/paths.txt:16:"
expect_prefix "src/paths.txt:17: [paths] "
expect_absent "src/paths.txt:18:"
[[ $failures -eq $before ]] && pass

current="double-escaped home paths are reported"
before=$failures
expect_prefix "src/paths.txt:11: [paths] "
[[ $failures -eq $before ]] && pass

current="account ids with numeric values are reported"
before=$failures
expect_prefix "Tests/Fixtures/run/event.json:6: [fixtures] "
expect_prefix "Tests/Fixtures/run/event.json:7: [fixtures] "
[[ $failures -eq $before ]] && pass

current="bare subspace refs are reported, qualified ones allowed"
before=$failures
expect_prefix "src/plan.md:4: [plan-refs] "
expect_absent "src/plan.md:18:"
[[ $failures -eq $before ]] && pass

current="image placeholders in prompts are no issue refs, refs after them are"
before=$failures
expect_absent "src/plan.md:19:"
expect_prefix "src/plan.md:20: [plan-refs] "
[[ $failures -eq $before ]] && pass

current="the root LICENSE is checked, third-party licenses are not"
before=$failures
expect_prefix "LICENSE:1: [addresses] "
expect_absent "LICENSE-icons:"
expect_absent "vendor/lib/LICENSE:"
[[ $failures -eq $before ]] && pass

current="plugin refs to the private owner are reported"
before=$failures
expect_prefix "src/repo.swift:3: [private-repo] "
[[ $failures -eq $before ]] && pass

current="German decisions, refs next to slashes and comparisons are reported"
before=$failures
for line in 11 15 16; do
  expect_prefix "src/plan.md:$line: [plan-refs] "
done
[[ $failures -eq $before ]] && pass

current="headings, Swift directives, colours and URL fragments are no issue refs"
before=$failures
for line in 1 5 6 7 8 9 12 13 14 17; do
  expect_absent "src/plan.md:$line:"
done
expect_absent "src/style.css"
[[ $failures -eq $before ]] && pass

current="identity: name, addresses, login and host name, in and out of Fixtures/"
before=$failures
for line in 1 2 3 5 6 7; do
  expect_prefix "src/people.txt:$line: [identity] "
done
expect_absent "src/people.txt:4:"
expect_absent "src/people.txt:9:"
expect_prefix "Tests/Fixtures/run/event.json:4: [identity] "
expect_prefix "Tests/Fixtures/run/event.json:5: [identity] "
expect_absent "Tests/Fixtures/run/event.json:4: [fixtures]"
[[ $failures -eq $before ]] && pass

current="identity skips a name after a home prefix only while paths runs"
before=$failures
expect_prefix "src/people.txt:8: [paths] "
expect_absent "src/people.txt:8: [identity]"
expect_prefix "src/people.txt:14: [paths] "
expect_absent "src/people.txt:14: [identity]"
expect_prefix "src/people.txt:15: [paths] "
expect_absent "src/people.txt:15: [identity]"
run "$CHECK" --rule identity
expect_code 1
expect_prefix "src/people.txt:8: [identity] "
expect_prefix "src/people.txt:14: [identity] "
expect_prefix "src/people.txt:15: [identity] "
expect_line "identity       15"
[[ $failures -eq $before ]] && pass

current="identity skips only the exact prefixes paths reports"
before=$failures
run "$CHECK"
for line in 10 11 12 13; do
  expect_prefix "src/people.txt:$line: [identity] "
  expect_absent "src/people.txt:$line: [paths]"
done
[[ $failures -eq $before ]] && pass

current="PUBLIC_CHECK_IDENTITY_EXTRA adds strings"
before=$failures
run env PUBLIC_CHECK_IDENTITY_EXTRA="zorblax quuxly" "$CHECK" --rule identity
expect_prefix "src/people.txt:9: [identity] "
expect_line "identity       16"
[[ $failures -eq $before ]] && pass

current="a generic login or host name is no identity"
before=$failures
run env PC_STUB_LOGIN=user PC_STUB_HOST=dev "$CHECK" --rule identity
expect_code 1
expect_prefix "src/people.txt:1: [identity] "
expect_absent "src/people.txt:16:"
expect_absent "src/paths.txt:2:"
expect_absent "src/paths.txt:5:"
run env PC_STUB_LOGIN=zorblax PC_STUB_HOST=Root "$CHECK" --rule identity
expect_prefix "src/people.txt:9: [identity] "
expect_absent "src/people.txt:16:"
# The login of a hosted CI machine.
run env PC_STUB_LOGIN=runner PC_STUB_HOST=dev "$CHECK" --rule identity
expect_absent "src/people.txt:17:"
[[ $failures -eq $before ]] && pass

current="snippets stay valid UTF-8"
before=$failures
run "$CHECK" --rule plan-refs
expect_prefix "src/long.txt:1: [plan-refs] "
iconv -f UTF-8 -t UTF-8 <<<"$out" >/dev/null 2>&1 || fail "output is not valid UTF-8"
[[ $failures -eq $before ]] && pass

current="design item ids in parentheses, ranges, lists, labels and after keywords"
before=$failures
run "$CHECK" --rule design-ids
expect_code 1
for line in $(seq 1 16); do
  expect_prefix "src/design.swift:$line: [design-ids] "
done
expect_line "design-ids     16"
[[ $failures -eq $before ]] && pass

current="key names, headings, escapes, hex, versions, call ids and capture runs are no design ids"
before=$failures
for line in $(seq 17 25); do
  expect_absent "src/design.swift:$line:"
done
[[ $failures -eq $before ]] && pass

current="the design-ids rule skips Fixtures/"
before=$failures
expect_absent "Tests/Fixtures/run/notes.json"
[[ $failures -eq $before ]] && pass

current="the fixtures rule only reads Fixtures/"
before=$failures
run "$CHECK"
expect_absent "src/session.swift"
[[ $failures -eq $before ]] && pass

current="skips the planning folder and untracked files"
before=$failures
expect_absent "$planning/todo.md:"
expect_absent "AGENTS.md:"
[[ $failures -eq $before ]] && pass

current="--summary prints the counts only"
before=$failures
run "$CHECK" --summary
expect_code 1
expect_absent "src/"
expect_line "total          59"
[[ $failures -eq $before ]] && pass

# The check is slow enough that the reader has gone before the first write.
current="a reader that stops early causes no write error"
before=$failures
run bash -c "'$CHECK' | true; echo \"exit \${PIPESTATUS[0]}\""
expect_line "exit 1"
expect_absent "Broken pipe"
run bash -c "trap '' PIPE; '$CHECK' | true; echo \"exit \${PIPESTATUS[0]}\""
expect_line "exit 1"
expect_absent "Broken pipe"
[[ $failures -eq $before ]] && pass

current="--rule takes a comma list"
before=$failures
run "$CHECK" --rule paths,addresses
expect_code 1
expect_absent "[plan-refs]"
expect_absent "plan-refs "
expect_line "paths          12"
expect_line "addresses      3"
expect_line "total          15"
[[ $failures -eq $before ]] && pass

current="--rule can be repeated"
before=$failures
run "$CHECK" --rule private-repo --rule fixtures
expect_code 1
expect_absent "[paths]"
expect_line "private-repo   2"
expect_line "fixtures       4"
expect_line "total          6"
[[ $failures -eq $before ]] && pass

# What is left are the committed checker and its allow file, which must
# not report themselves.
current="exit 0 without findings, also for the checker itself"
before=$failures
(
  cd "$REPO"
  git rm --quiet -r src Tests LICENSE
  git commit --quiet -m clean
)
run "$CHECK"
expect_code 0
expect_line "total          0"
[[ $failures -eq $before ]] && pass

current="runs from any directory"
before=$failures
run bash -c "cd / && '$CHECK' --summary"
expect_code 0
expect_line "total          0"
[[ $failures -eq $before ]] && pass

# The identity comes from the checkout the checker lives in, not from the
# one it checks.
current="--root checks another checkout with the checker's identity"
before=$failures
other="$TMP/other"
mkdir -p "$other"
(
  cd "$other"
  git init --quiet --initial-branch=main
  git config user.name "Zed Quux"
  git config user.email "zed${at}quux-mail.io"
  printf '%s\n' "see ${hash}42" "Thanks, Jane" "Thanks, Zed" >notes.md
  git add notes.md
  git commit --quiet -m init
)
run "$CHECK" --root "$other/"
expect_code 1
expect_line "notes.md:1: [plan-refs] see ${hash}42"
expect_line "notes.md:2: [identity] Thanks, Jane"
expect_absent "notes.md:3:"
expect_line "total          2"
[[ $failures -eq $before ]] && pass

# The global git config may be unreadable (no HOME); the checkout's own
# config then holds one of user.name and user.email at most.
current="identity: the name comes from the history of user.email"
before=$failures
byemail="$TMP/byemail"
mkdir -p "$byemail/scripts"
cp "$SCRIPTS/public-check.sh" "$SCRIPTS/public-check.allow" "$byemail/scripts/"
(
  cd "$byemail"
  git init --quiet --initial-branch=main
  git config user.email "JRoe${at}roe-mail.io"
  as_jane=(-c "user.name=Jane Roe" -c "user.email=jroe${at}roe-mail.io")
  git "${as_jane[@]}" commit --quiet --allow-empty -m start --author="Jane Roe <jane.roe${at}old-mail.io>"
  printf '%s\n' "Reviewed by Jane." "Domain: old-mail.io" "Mail jroe${at}roe-mail.io" >notes.md
  git add .
  git "${as_jane[@]}" commit --quiet -m init
)
run env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$byemail/scripts/public-check.sh" --rule identity
expect_code 1
expect_prefix "notes.md:1: [identity] "
expect_prefix "notes.md:2: [identity] "
expect_prefix "notes.md:3: [identity] "
expect_absent "warning:"
[[ $failures -eq $before ]] && pass

current="identity: warns when neither user.name nor user.email is readable"
before=$failures
git -C "$byemail" config --unset user.email
run env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$byemail/scripts/public-check.sh" --rule identity
expect_code 0
expect_prefix "warning: neither user.name nor user.email is readable"
expect_absent "notes.md:"
[[ $failures -eq $before ]] && pass

current="usage errors exit 2"
before=$failures
run "$CHECK" --rule nope
expect_code 2
run "$CHECK" --bogus
expect_code 2
run "$CHECK" --rule
expect_code 2
run "$CHECK" --root "$TMP/missing"
expect_code 2
run "$CHECK" -h
expect_code 0
expect_prefix "usage: scripts/public-check.sh"
[[ $failures -eq $before ]] && pass

current="an allow entry without a reason is an error"
before=$failures
echo "paths text ^/$users/jdoe$" >>"$REPO/scripts/public-check.allow"
run "$CHECK"
expect_code 2
expect_prefix "public-check.allow:"
[[ $failures -eq $before ]] && pass

if [[ $failures -gt 0 ]]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
