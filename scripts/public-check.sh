#!/usr/bin/env bash
# Reports everything in the tracked tree that must not go into the public
# repo: home paths with real names, references to private repositories,
# references to the planning folder, decisions and this repo's issue numbers
# (they change with the move), the item ids of the design references in the
# planning folder, e-mail addresses, the name, login, host name
# and addresses of whoever runs the check, and in captured fixtures account
# identifiers and credentials.
#
#   scripts/public-check.sh [--summary] [--rule <id>[,<id>…]]… [--root <dir>]
#
# Only tracked files are read (git grep, binary files skipped), never the
# planning folder `tasks`, which does not move. Exceptions, each with a
# reason, live in public-check.allow next to this script.
#
# The identity rule reads its strings at run time, so that this file names
# nobody: `id -un` and `hostname -s` of this machine, the words of
# `user.name` and the address in `user.email` of the git config of the
# checkout this script lives in (also with --root), the author names that
# committed there with that address, the other addresses those names
# committed with, and the whitespace-separated strings in
# PUBLIC_CHECK_IDENTITY_EXTRA.
#
# Exit 0 without findings, 1 with findings, 2 on an error: usage, a missing
# or malformed allow file, a failing git or a failed write.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOW_FILE="$SCRIPT_DIR/public-check.allow"
readonly SCRIPT_DIR ALLOW_FILE
readonly RULES="paths private-repo plan-refs design-ids addresses identity fixtures"

usage() {
  cat <<'EOF'
usage: scripts/public-check.sh [--summary] [--rule <id>[,<id>...]]... [--root <dir>]

Reports tracked files (without the tasks folder) that carry data the public
repo must not have, as `path:line: [rule] match`, then a count per rule.

  --summary      counts only
  --rule <ids>   only these rules; repeat the option or separate ids by commas
                 (paths, private-repo, plan-refs, design-ids, addresses,
                 identity, fixtures)
  --root <dir>   check the git checkout at <dir> instead of this one (the
                 identity still comes from this one's git config)
  -h, --help     this text

PUBLIC_CHECK_IDENTITY_EXTRA: more identity strings, separated by spaces.
Exceptions: scripts/public-check.allow. Exit 0 without findings, 1 with
findings, 2 on an error (usage, allow file, git or a failed write).
EOF
}

usage_error() {
  echo "error: $*" >&2
  usage >&2
  exit 2
}

summary=0
selected=""
root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --summary) summary=1 ;;
    --rule)
      [[ $# -ge 2 ]] || usage_error "--rule needs a rule id"
      selected="$selected ${2//,/ }"
      shift
      ;;
    --root)
      [[ $# -ge 2 ]] || usage_error "--root needs a directory"
      root="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) usage_error "unknown argument: $1" ;;
  esac
  shift
done

for id in $selected; do
  case " $RULES " in
    *" $id "*) ;;
    *) usage_error "unknown rule: $id" ;;
  esac
done
[[ -n "${selected// /}" ]] || selected="$RULES"

if [[ -z "$root" ]]; then
  root="$SCRIPT_DIR"
fi
[[ -d "$root" ]] || usage_error "not a directory: $root"
root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" ||
  usage_error "not inside a git checkout: $root"
[[ -f "$ALLOW_FILE" ]] || usage_error "allow file missing: $ALLOW_FILE"

# Split so that this file does not report itself for the private-repo rule.
owner="grm"
owner="${owner}lin"

# Who runs the check (see the header). Too short a string, a generic local
# part or a mail provider's domain would match what is nobody's.
readonly GENERIC_LOCALS=" admin administrator contact dev developer git guest hello info mail noreply root runner test user "
readonly GENERIC_DOMAINS=" gmail.com googlemail.com icloud.com me.com mac.com outlook.com hotmail.com live.com yahoo.com gmx.de gmx.net web.de proton.me protonmail.com pm.me posteo.de mailbox.org fastmail.com users.noreply.github.com "
ere_escape() {
  printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'
}
identity_alts=""
add_identity() {
  local text
  text="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ ${#text} -ge 3 && "$text" != "localhost" ]] || return 0
  text="$(ere_escape "$text")"
  case "|$identity_alts|" in
    *"|$text|"*) return 0 ;;
  esac
  identity_alts="${identity_alts:+$identity_alts|}$text"
}
add_address() {
  local address local_part domain
  address="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$address" == ?*@?* ]] || return 0
  local_part="${address%@*}" domain="${address##*@}"
  add_identity "$address"
  [[ " $GENERIC_LOCALS " == *" $local_part "* ]] || add_identity "$local_part"
  case "$domain" in
    example.* | *.example | *.invalid | *.test) ;;
    *) [[ " $GENERIC_DOMAINS " == *" $domain "* ]] || add_identity "$domain" ;;
  esac
}
# A generic login or host name (a container's `root`, a VM's `dev`, the
# `runner` of a hosted CI machine) names nobody and would fight the allowed
# scrubbed home `/Users/user`.
add_word() {
  local word
  word="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ " $GENERIC_LOCALS " == *" $word "* ]] || add_identity "$word"
}
add_word "$(id -un 2>/dev/null || true)"
add_word "$(hostname -s 2>/dev/null || true)"
# Either of user.name and user.email leads to the other through the
# history, so that a global config that cannot be read (no HOME) while the
# checkout's own config holds one of them costs nothing.
git_name="$(git -C "$SCRIPT_DIR" config user.name 2>/dev/null || true)"
git_email="$(git -C "$SCRIPT_DIR" config user.email 2>/dev/null || true)"
if [[ -z "$git_name" && -z "$git_email" ]]; then
  echo "warning: neither user.name nor user.email is readable from the git config;" \
    "the identity rule runs with the login and host name only" >&2
fi
git_names="$git_name"
git_addresses="$git_email"
if [[ -n "$git_name$git_email" ]]; then
  authors="$(git -C "$SCRIPT_DIR" log --format='%an%x09%ae' 2>/dev/null | sort -u || true)"
  git_names="$(
    printf '%s\n' "$git_name"
    printf '%s\n' "$authors" |
      awk -F '\t' -v email="$git_email" 'email != "" && tolower($2) == tolower(email) { print $1 }'
  )"
  git_addresses="$(
    printf '%s\n' "$git_email"
    printf '%s\n' "$authors" | PC_NAMES="$git_names" awk -F '\t' '
      BEGIN { n = split(ENVIRON["PC_NAMES"], list, "\n"); for (i = 1; i <= n; i++) if (list[i] != "") names[list[i]] = 1 }
      $1 in names { print $2 }'
  )"
fi
while IFS= read -r name; do
  read -r -a name_words <<<"$(printf '%s' "$name" | tr -s '[:space:][:punct:]' ' ')" || true
  for word in ${name_words[@]+"${name_words[@]}"}; do
    add_identity "$word"
  done
done <<<"$git_names"
while IFS= read -r address; do
  add_address "$address"
done <<<"$git_addresses"
read -r -a extra <<<"${PUBLIC_CHECK_IDENTITY_EXTRA:-}" || true
for word in ${extra[@]+"${extra[@]}"}; do
  add_identity "$word"
done

# rule <TAB> flags <TAB> ERE (git grep -E and awk). Flags:
#   i  matches the lower-cased line (the pattern is lower case)
#   h  skips a match right after a home-path prefix of the paths rule
#      (`/Users/`, `-Users-`, `/home/`, slashes escaped or not) while that
#      rule, which reports the whole path, runs too
#
# A home path counts only where a path starts, not after a letter, digit or
# `- _ .` (an escaped `\n`, `\r` or `\t` is a start), so that a URL such as
# `github.com/<org>/home/…` is none.
#   c  skips a colour: an all-digit `#nnn` or `#nnnn` (CSS short hex) in a
#      .css or .svg file, after an assignment `=` (not `==`), after a colour
#      key and `:` or `=`, or alone in quotes
#   u  skips a ref whose repo part ends in a document extension (`.md#…`)
#
# Issue refs, in this order of precedence: a `#n` right after a URL or path
# character (letter, digit, `_ . & / ) -`) is a fragment or part of a word,
# never a ref; a `[owner/]repo#n` counts only when it starts its own word
# (not after `. : /`, so `example.com/page#…` is a fragment) and the owner
# has no dot; everything else that is a `#` with 1 to 4 digits is a ref
# unless it is a colour (flag c).
# Read with `read`, not `$(cat <<…)`: bash 3.2 miscounts the unbalanced `)`
# in the first issue-ref pattern inside a command substitution.
patterns=""
IFS= read -r -d '' patterns <<'EOF' || true
paths	-	(^|[^A-Za-z0-9._-]|\\[nrt])\\*/Users\\*/[A-Za-z0-9._-]+
paths	-	-Users-[A-Za-z0-9._]+([^A-Za-z0-9._]|$)
paths	-	(^|[^A-Za-z0-9._-]|\\[nrt])\\*/home\\*/[A-Za-z0-9._-]+
paths	-	/var/folders/[A-Za-z0-9_+]{2}/
plan-refs	c	(^|[^A-Za-z0-9_.&/)-])#[1-9][0-9]{0,3}([^0-9A-Za-z_-]|$)
plan-refs	u	(^|[^A-Za-z0-9_.:/-])[A-Za-z0-9-]+(/[A-Za-z0-9_.-]+)?#[1-9][0-9]{0,3}([^0-9A-Za-z_-]|$)
plan-refs	-	[Dd]ecisions?[[:space:]]+[0-9]+
plan-refs	-	[Ee]ntscheidung(en)?[[:space:]]+[0-9]+
plan-refs	-	(^|[^A-Za-z0-9_.-])task[s]/[A-Za-z0-9_./-]*
addresses	-	[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}
fixtures	-	\\?"(organizationUuid|organization_uuid|accountUuid|account_uuid|account_id|creator_account_id|user_id|creator_user_id)\\?"[[:space:]]*:[[:space:]]*(\\?"[^"\\]*|[0-9]+)
fixtures	-	sk-ant-[A-Za-z0-9_-]+
fixtures	-	(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}
fixtures	-	gh[opsu]_[A-Za-z0-9]{20,}
fixtures	-	github_pat_[A-Za-z0-9_]{20,}
fixtures	-	xox[abp]-[A-Za-z0-9-]{10,}
fixtures	-	Bearer[[:space:]]+[A-Za-z0-9._~+/=-]{16,}
fixtures	-	(api_key|apiKey|API_KEY)\\?"?[[:space:]]*[:=][[:space:]]*\\?"?[A-Za-z0-9_-]{8,}
fixtures	-	AKIA[0-9A-Z]{16}
fixtures	-	-----BEGIN [A-Z ]*PRIVATE KEY-----
EOF
patterns+="$(printf 'private-repo\t-\t[A-Za-z0-9_.:/@-]*%s[A-Za-z0-9_.:/-]*' "$owner")"$'\n'

# Design item ids: a prefix letter of the design references, 1 or 2 digits
# and an optional variant letter (X12, X3a with X one of the letters below).
# Alone such a token is too often something else (a function key, a heading
# level, a tool call id in a test, a capture run), so it counts only where
# the references put their ids: in parentheses, alone, before another
# separator, a variant letter or a short word, or last in a list; in a range
# or a slash or comma list of ids; as a board scenario (X12-03, not a
# capture's three-digit hook number); as the label opening a comment; and
# after design, board, item or a decision number. Not in Fixtures/, which
# hold captured data.
did='[ACDFGHJKLNOPQRSUW][0-9]{1,2}[a-z]?'
dstart='(^|[^A-Za-z0-9_.#-])' dend='([^A-Za-z0-9_]|$)' ddash='(–|-)'
design_ere="\\(${did}([),;:/]| [A-Z][),:]| (for|like|and|or) |${ddash}${did}${dend})"
design_ere+="|,[[:space:]]+${did}\\)"
design_ere+="|${dstart}${did}(${ddash}|/|,[[:space:]]*)${did}${dend}"
design_ere+="|${dstart}${did}-[0-9]{2}([^0-9A-Za-z_]|\$)"
design_ere+="|^[[:space:]]*(//+|#+|\\*|--)[[:space:]]*${did}(:| [A-Z][[:space:]:,])"
design_ere+="|([Dd]esign|[Bb]oards?|[Ii]tems?|[Dd]ecisions?[[:space:]]+[0-9]+|[Ee]ntscheidung(en)?[[:space:]]+[0-9]+)[[:space:]]+\\(?${did}${dend}"
patterns+="design-ids"$'\t-\t'"$design_ere"$'\n'
[[ -z "$identity_alts" ]] ||
  patterns+="$(printf 'identity\tih\t(^|[^a-z0-9])(%s)([^a-z0-9]|$)' "$identity_alts")"$'\n'

# Allow file: `<rule|*> path <git glob>  # reason`,
# `<rule|*> text <ERE on the match>  # reason` or
# `<rule|*> line <ERE on the line up to the end of the match>  # reason`.
# Patterns hold no whitespace.
allow_paths=()
allow_texts=()
allow_lines=()
lineno=0
entry_re='^([a-z*-]+)[[:space:]]+(path|text|line)[[:space:]]+([^[:space:]]+)[[:space:]]+#[[:space:]]*[^[:space:]]'
while IFS= read -r line || [[ -n "$line" ]]; do
  lineno=$((lineno + 1))
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  if [[ ! "$line" =~ $entry_re ]]; then
    echo "error: $ALLOW_FILE:$lineno: expected '<rule> path|text|line <pattern>  # reason'" >&2
    exit 2
  fi
  rule="${BASH_REMATCH[1]}" kind="${BASH_REMATCH[2]}" pattern="${BASH_REMATCH[3]}"
  if [[ "$rule" != "*" && " $RULES " != *" $rule "* ]]; then
    echo "error: $ALLOW_FILE:$lineno: unknown rule: $rule" >&2
    exit 2
  fi
  case "$kind" in
    path) allow_paths+=("$rule	$pattern") ;;
    text) allow_texts+=("$rule	$pattern") ;;
    line) allow_lines+=("$rule	$pattern") ;;
  esac
done <"$ALLOW_FILE"

# Prints the EREs of the entries "$2"… that apply to rule $1, one per line.
allowed_for() {
  local rule="$1" entry
  shift
  for entry in "$@"; do
    case "$entry" in
      "$rule	"* | "*	"*) printf '%s\n' "${entry#*	}" ;;
    esac
  done
}

skip_home=0
[[ " $selected " == *" paths "* ]] && skip_home=1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/findings"

while IFS='	' read -r rule flags ere; do
  [[ -n "$rule" ]] || continue
  case " $selected " in
    *" $rule "*) ;;
    *) continue ;;
  esac

  scope=(.)
  [[ "$rule" == "fixtures" ]] && scope=(':(glob)**/Fixtures/**')
  [[ "$rule" == "design-ids" ]] && scope+=(':(exclude,glob)**/Fixtures/**')
  scope+=(':(exclude)tasks')
  for entry in ${allow_paths[@]+"${allow_paths[@]}"}; do
    case "$entry" in
      "$rule	"* | "*	"*) scope+=(":(exclude,glob)${entry#*	}") ;;
    esac
  done

  case_flag=()
  [[ "$flags" == *i* ]] && case_flag=(-i)

  status=0
  git -C "$root" grep -n -I -E ${case_flag[@]+"${case_flag[@]}"} -e "$ere" -- "${scope[@]}" \
    >"$tmp/hits" 2>"$tmp/err" || status=$?
  if [[ $status -gt 1 ]]; then
    echo "error: git grep failed for [$rule] $ere:" >&2
    cat "$tmp/err" >&2
    exit 2
  fi

  # First match on each line that no text exception allows, with a little
  # context, at most 160 characters.
  # Snippets are cut on bytes (LC_ALL=C keeps awk fast) and then moved off
  # UTF-8 continuation bytes, so that no character is split.
  PC_RULE="$rule" PC_FLAGS="$flags" PC_ERE="$ere" \
    PC_ALLOW="$(allowed_for "$rule" ${allow_texts[@]+"${allow_texts[@]}"})" \
    PC_ALLOW_LINE="$(allowed_for "$rule" ${allow_lines[@]+"${allow_lines[@]}"})" \
    PC_SKIP_HOME="$skip_home" awk '
    BEGIN {
      rule = ENVIRON["PC_RULE"]; flags = ENVIRON["PC_FLAGS"]; ere = ENVIRON["PC_ERE"]
      skip_home = ENVIRON["PC_SKIP_HOME"] == "1"
      n = split(ENVIRON["PC_ALLOW"], allow, "\n")
      m = split(ENVIRON["PC_ALLOW_LINE"], allow_line, "\n")
    }
    function allowed(hit, upto,   i) {
      for (i = 1; i <= n; i++) if (allow[i] != "" && hit ~ allow[i]) return 1
      for (i = 1; i <= m; i++) if (allow_line[i] != "" && upto ~ allow_line[i]) return 1
      return 0
    }
    function continuation(c) { return c >= "\200" && c < "\300" }
    # The hit holds one `#` and its digits; see the patterns for the rule.
    function colour(hit, start,   h, digits, before, after) {
      h = index(hit, "#"); digits = substr(hit, h + 1); sub(/[^0-9].*$/, "", digits)
      if (length(digits) < 3 || length(digits) > 4) return 0
      if (path ~ /\.(css|scss|svg)$/) return 1
      before = tolower(substr(text, 1, start + h - 2))
      after = substr(text, start + h + length(digits), 1)
      if (before ~ /(^|[^=!<>])=[ ]*["\047]?$/) return 1
      if (before ~ /(colou?r|fill|stroke|background|border|tint|foreground|base[0-9a-f][0-9a-f])["\047]?[ ]*[:=][ ]*["\047]?$/) return 1
      return before ~ /["\047]$/ && after == substr(before, length(before))
    }
    {
      p = index($0, ":"); path = substr($0, 1, p - 1); rest = substr($0, p + 1)
      q = index(rest, ":"); line = substr(rest, 1, q - 1); text = substr(rest, q + 1)
      gsub(/\t/, " ", text)
      subject = (flags ~ /i/) ? tolower(text) : text
      offset = 0
      while (offset < length(subject) && match(substr(subject, offset + 1), ere)) {
        start = offset + RSTART; len = RLENGTH
        offset = start + (len > 0 ? len : 1) - 1
        hit = substr(text, start, len)
        # The match starts with the character before the name.
        # Case-sensitive and only the prefixes the paths patterns take, so
        # that paths has reported every line this skips.
        if (flags ~ /h/ && skip_home && substr(text, 1, start) ~ /((^|[^A-Za-z0-9._-]|\\[nrt])\\*\/(Users|home)\\*\/|-Users-)$/) continue
        if (flags ~ /c/ && colour(hit, start)) continue
        if (flags ~ /u/ && hit ~ /\.(md|markdown|html?|txt|pdf)#/) continue
        if (allowed(hit, substr(text, 1, start + len - 1))) continue
        from = start - 40; if (from < 1) from = 1
        to = start + len + 40; if (to - from > 160) to = from + 160
        while (from < start && continuation(substr(text, from, 1))) from++
        while (to > start + len && continuation(substr(text, to, 1))) to--
        snippet = substr(text, from, to - from)
        sub(/^ +/, "", snippet); sub(/ +$/, "", snippet)
        printf "%s\t%s\t%s\t%s:%s: [%s] %s\n", path, line, rule, path, line, rule, snippet
        break
      }
    }' "$tmp/hits" >>"$tmp/findings"
done <<<"$patterns"

# One finding per line and rule, in file order.
sort -t '	' -k1,1 -k2,2n -k3,3 "$tmp/findings" |
  awk -F '\t' '!seen[$1 FS $2 FS $3]++' >"$tmp/sorted"

total=0
{
  if [[ $summary -eq 0 ]]; then
    cut -f4- "$tmp/sorted"
    [[ -s "$tmp/sorted" ]] && echo
  fi
  for id in $RULES; do
    case " $selected " in
      *" $id "*) ;;
      *) continue ;;
    esac
    count="$(awk -F '\t' -v r="$id" '$3 == r' "$tmp/sorted" | wc -l | tr -d ' ')"
    printf '%-14s %s\n' "$id" "$count"
    total=$((total + count))
  done
  printf '%-14s %s\n' "total" "$total"
} >"$tmp/report"

# Written in one go, so that a reader that stops early (`| head`) is the one
# write error that stays quiet: killed by SIGPIPE (141) or, with SIGPIPE
# ignored, EPIPE. A shell cannot reset an ignored SIGPIPE.
status=0
cat "$tmp/report" 2>"$tmp/err" || status=$?
if [[ $status -ne 0 && $status -ne 141 ]] && ! grep -q 'Broken pipe' "$tmp/err"; then
  cat "$tmp/err" >&2
  exit 2
fi

[[ $total -eq 0 ]]
