#!/usr/bin/env bash
# Tests for scripts/release.sh, run against a copy of it in a throwaway repo
# with a local bare `origin`: never the real repo, its build/ or origin.
# xcodebuild, xcrun, spctl, gh and git-cliff are stubs that log their argv;
# git, ditto and PlistBuddy are real.
#
#   scripts/test-release.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/release.sh"
TMP="$(mktemp -d)"
readonly SCRIPT TMP
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

# Stubs, each appending "<name> <argv>" to $STUB_LOG.
make_stubs() {
  local bin="$TMP/bin"
  mkdir -p "$bin"

  # The archive step leaves Sparkle's sign_update in the DerivedData, as the
  # package does; it prints a fixed signature and the zip's real length.
  cat >"$bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
echo "xcodebuild $*" >>"$STUB_LOG"
export_path="" derived_data=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "-exportPath" ]] && export_path="$2"
  [[ "$1" == "-derivedDataPath" ]] && derived_data="$2"
  shift
done
if [[ -n "$derived_data" ]]; then
  tools="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin"
  mkdir -p "$tools"
  cat >"$tools/sign_update" <<'SIGN'
#!/usr/bin/env bash
echo "sign_update $*" >>"$STUB_LOG"
echo "sparkle:edSignature=\"c2lnbmF0dXJl\" length=\"$(stat -f %z "$1")\""
SIGN
  chmod +x "$tools/sign_update"
fi
if [[ -n "$export_path" ]]; then
  mkdir -p "$export_path/The Collective.app/Contents"
  cat >"$export_path/The Collective.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>9.9.9</string>
</dict>
</plist>
PLIST
fi
EOF

  cat >"$bin/xcrun" <<'EOF'
#!/usr/bin/env bash
echo "xcrun $*" >>"$STUB_LOG"
if [[ "$1" == "notarytool" ]]; then
  echo "  id: 123"
  echo "  status: Accepted"
fi
EOF

  # Fails once while $SPCTL_FAIL_ONCE names an existing file (and removes it).
  cat >"$bin/spctl" <<'EOF'
#!/usr/bin/env bash
echo "spctl $*" >>"$STUB_LOG"
if [[ -n "${SPCTL_FAIL_ONCE:-}" && -f "$SPCTL_FAIL_ONCE" ]]; then
  rm -f "$SPCTL_FAIL_ONCE"
  echo "$2: rejected"
  exit 3
fi
echo "$2: accepted"
echo "source=Notarized Developer ID"
EOF

  # `api …/releases/latest` answers $GH_LATEST, or 404 while it is unset
  # ($GH_API_FAILS: another error); `release download` writes a previous
  # appcast unless $GH_NO_APPCAST is set.
  cat >"$bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB_LOG"
if [[ "$1" == "api" && "$2" == *"/releases/latest" ]]; then
  if [[ -n "${GH_API_FAILS:-}" ]]; then echo "error connecting to api.github.com" >&2; exit 1; fi
  if [[ -z "${GH_LATEST:-}" ]]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
  echo "$GH_LATEST"
elif [[ "$1 $2" == "release download" ]]; then
  [[ -z "${GH_NO_APPCAST:-}" ]] || { echo "no assets match the file pattern" >&2; exit 1; }
  dir=""
  while [[ $# -gt 0 ]]; do [[ "$1" == "--dir" ]] && dir="$2"; shift; done
  echo "<rss>previous</rss>" >"$dir/appcast.xml"
fi
EOF

  # `swift run … collective-appcast`: writes its arguments to --output.
  cat >"$bin/swift" <<'EOF'
#!/usr/bin/env bash
echo "swift $*" >>"$STUB_LOG"
output=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" == "--output" ]] && output="${args[i + 1]}"; done
echo "appcast from: $*" >"$output"
EOF

  # `--bumped-version` answers v9.10.0; `--tag vX.Y.Z --prepend <file>` puts a
  # section for it above the first `## ` heading, like the real one below its
  # header.
  cat >"$bin/git-cliff" <<'EOF'
#!/usr/bin/env bash
echo "git-cliff $*" >>"$STUB_LOG"
tag="" file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bumped-version) echo "v9.10.0" ;;
    --tag) tag="$2" ;;
    --prepend) file="$2" ;;
  esac
  shift
done
if [[ -n "$file" ]]; then
  awk -v heading="## ${tag#v}" '
    !done && /^## / { print heading; print ""; print "- A test feature"; print ""; done = 1 }
    { print }
  ' "$file" >"$file.new"
  mv "$file.new" "$file"
fi
EOF

  chmod +x "$bin"/*
  PATH="$bin:$PATH"
}

# The copy of ReleaseNotes.md the app bundles.
readonly BUNDLED_NOTES="CollectiveKit/Sources/CollectiveKit/Resources/ReleaseNotes.md"

# A fresh origin plus a clone on main with version 9.9.9, its changelog
# section and its user release notes with their bundled copy, all in one
# commit so HEAD is the release commit.
new_repo() {
  local dir="$TMP/$1"
  git init --quiet --bare --initial-branch=main "$dir/origin.git"
  git init --quiet --initial-branch=main "$dir/clone"
  (
    cd "$dir/clone"
    git config user.name "Release Test"
    git config user.email "release-test@example.invalid"
    git config commit.gpgsign false
    git config tag.gpgsign false
    mkdir -p scripts App "$(dirname "$BUNDLED_NOTES")"
    cp "$SCRIPT" scripts/release.sh
    echo "MARKETING_VERSION = 9.9.9" >App/Version.xcconfig
    echo "<plist/>" >App/ExportOptions.plist
    printf '# Changelog\n\n## 9.9.9\n\n- A test release\n' >CHANGELOG.md
    printf '# Release Notes\n\nWritten by hand.\n\n## 9.9.9\n\nThe first test release.\n' >ReleaseNotes.md
    cp ReleaseNotes.md "$BUNDLED_NOTES"
    echo "/build/" >.gitignore
    git add -A
    git commit --quiet -m "chore(release): v9.9.9"
    git remote add origin "$dir/origin.git"
    git push --quiet -u origin main
  )
  REPO="$dir/clone"
  ORIGIN="$dir/origin.git"
}

# Runs release.sh in $REPO with stdin from $1 and the remaining arguments;
# sets STATUS, OUTPUT and STUB_LOG (fresh per run).
run() {
  local input="$1"
  shift
  STUB_LOG="$(mktemp "$TMP/log.XXXXXX")"
  export STUB_LOG
  set +e
  OUTPUT="$(cd "$REPO" && bash scripts/release.sh "$@" <"$input" 2>&1)"
  STATUS=$?
  set -e
}

# Like `run`, but in a pseudo-terminal driven by expect (part of macOS),
# which waits for each `[y/N]` prompt and answers with the next word of $1,
# so the interactive path of `confirm` is exercised.
run_in_terminal() {
  local answers="$1"
  shift
  STUB_LOG="$(mktemp "$TMP/log.XXXXXX")"
  export STUB_LOG
  set +e
  # shellcheck disable=SC2016 # the $ are Tcl's, not the shell's
  OUTPUT="$(cd "$REPO" && ANSWERS="$answers" ARGS="$*" expect -c '
    set timeout 60
    spawn bash scripts/release.sh {*}$env(ARGS)
    foreach answer $env(ANSWERS) {
      expect {
        "\\\[y/N\\\] " { send "$answer\r" }
        eof { break }
      }
    }
    expect eof
    exit [lindex [wait] 3]
  ' 2>&1)"
  STATUS=$?
  set -e
}

# Replaces ReleaseNotes.md and its bundled copy in the release commit with $1
# (no argument: no file), so HEAD stays the release commit.
set_release_notes() {
  (
    cd "$REPO"
    if [[ $# -eq 0 ]]; then
      git rm --quiet ReleaseNotes.md
    else
      printf '%s' "$1" >ReleaseNotes.md
      cp ReleaseNotes.md "$BUNDLED_NOTES"
      git add ReleaseNotes.md "$BUNDLED_NOTES"
    fi
    git commit --quiet --amend --no-edit
    git push --quiet --force origin main
  )
}

# The state `prepare` starts from: v9.9.9 is tagged and a feature merged since.
released_with_feature() {
  (
    cd "$REPO"
    git tag v9.9.9
    echo "feature" >feature.txt
    git add feature.txt
    git commit --quiet -m "feat: a test feature"
    git push --quiet origin main
  )
}

logged() {
  grep -q -- "$1" "$STUB_LOG"
}

released_on_origin() {
  git --git-dir="$ORIGIN" rev-parse --quiet --verify refs/tags/v9.9.9 >/dev/null &&
    logged "gh release create v9.9.9 "
}

marker() {
  cat "$REPO/build/release/v9.9.9/notarized-commit" 2>/dev/null || true
}

head_sha() {
  git -C "$REPO" rev-parse HEAD
}

case_no_terminal() {
  local command
  for command in publish prepare; do
    current="$command without a terminal and without --yes aborts"
    new_repo "no-terminal-$command"
    run /dev/null "$command"
    if [[ "$STATUS" -eq 0 ]]; then
      fail "exit status 0"
    elif [[ "$OUTPUT" != *"--yes"* || "$OUTPUT" != *"not a terminal"* ]]; then
      fail "message does not mention the terminal and --yes: $OUTPUT"
    elif [[ -s "$STUB_LOG" ]]; then
      fail "tools were called: $(cat "$STUB_LOG")"
    else
      pass
    fi
  done
}

case_publish_yes() {
  current="publish --yes builds, notarizes, tags and releases"
  new_repo publish-yes
  run /dev/null publish --yes
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif ! logged "^xcodebuild " || ! logged "^xcrun notarytool submit"; then
    fail "no build or notarization: $(cat "$STUB_LOG")"
  elif ! released_on_origin; then
    fail "no tag on origin or no GitHub release: $(cat "$STUB_LOG")"
  elif [[ "$(marker)" != "$(head_sha)" ]]; then
    fail "notarized-commit is '$(marker)', expected HEAD"
  elif [[ "$OUTPUT" != *"yes (--yes)"* ]]; then
    fail "the confirm question is not answered visibly: $OUTPUT"
  else
    pass
  fi
}

# The GitHub release text: the user notes on top, the changelog below, and
# the hint comment `prepare` leaves never reaches GitHub.
case_publish_notes_file() {
  current="publish writes the user notes above the changelog, without comments"
  new_repo publish-notes-file
  set_release_notes $'# Release Notes\n\n## 9.9.9\n\n<!-- a hint,\nover two lines -->\n\nThe first test release.\n\n<!-- another -->\n\n## 9.9.8\n\nAn older release.\n'
  run /dev/null publish --yes
  local expected
  expected=$'The first test release.\n\n---\n\n### Changes\n\n- A test release'
  local actual
  actual="$(cat "$REPO/build/release/v9.9.9/notes.md" 2>/dev/null || true)"
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif [[ "$actual" != "$expected" ]]; then
    fail "unexpected notes file: $actual"
  elif ! logged '--notes-file build/release/v9.9.9/notes.md'; then
    fail "gh release create does not use the notes file: $(cat "$STUB_LOG")"
  else
    pass
  fi
}

# The first run declines the final question in a terminal, which leaves a
# notarized but untagged build: the state a declined or interrupted publish
# leaves behind, without a failure that would already have tagged.
case_resume() {
  current="publish after a declined run reuses the notarized build"
  new_repo resume
  run_in_terminal n publish
  if [[ "$STATUS" -ne 0 ]]; then
    fail "first run: exit status $STATUS: $OUTPUT"
    return
  fi
  if [[ "$OUTPUT" != *"reuse"* ]]; then
    fail "first run: the decline text does not mention reusing the build: $OUTPUT"
    return
  fi
  if git --git-dir="$ORIGIN" rev-parse --quiet --verify refs/tags/v9.9.9 >/dev/null; then
    fail "first run: tagged although declined"
    return
  fi

  run /dev/null publish --yes
  if [[ "$STATUS" -ne 0 ]]; then
    fail "second run: exit status $STATUS: $OUTPUT"
  elif logged "^xcodebuild " || logged "^xcrun notarytool" || logged "^xcrun stapler"; then
    fail "second run built or notarized again: $(cat "$STUB_LOG")"
  elif [[ "$OUTPUT" != *"Reusing the notarized build from $(git -C "$REPO" rev-parse --short HEAD) in build/release/v9.9.9"* ]]; then
    fail "second run does not say it reuses the build: $OUTPUT"
  elif ! released_on_origin; then
    fail "second run: no tag on origin or no GitHub release"
  elif [[ ! -s "$REPO/build/release/v9.9.9/notes.md" ]]; then
    fail "second run: notes.md is missing"
  else
    pass
  fi
}

# A notarized, untagged build of the current HEAD, made by a declined run.
declined_build() {
  run_in_terminal n publish
  [[ "$STATUS" -eq 0 && "$(marker)" == "$(head_sha)" ]] || {
    fail "could not set up a declined build: $OUTPUT"
    return 1
  }
}

case_other_sha() {
  current="a marker for another commit is ignored and the app rebuilt"
  new_repo other-sha
  declined_build || return 0
  echo "0123456789abcdef0123456789abcdef01234567" >"$REPO/build/release/v9.9.9/notarized-commit"
  run /dev/null publish --yes
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif ! logged "^xcodebuild "; then
    fail "no rebuild: $(cat "$STUB_LOG")"
  elif [[ "$OUTPUT" == *"Reusing"* ]]; then
    fail "claims to reuse: $OUTPUT"
  elif [[ "$OUTPUT" != *"Ignoring"* ]]; then
    fail "no reason for ignoring the marker: $OUTPUT"
  elif [[ "$(marker)" != "$(head_sha)" ]]; then
    fail "notarized-commit not rewritten for HEAD"
  else
    pass
  fi
}

case_missing_zip() {
  current="a missing zip is not reused"
  new_repo missing-zip
  declined_build || return 0
  rm "$REPO/build/release/v9.9.9/The-Collective-9.9.9.zip"
  run /dev/null publish --yes
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif ! logged "^xcodebuild "; then
    fail "no rebuild: $(cat "$STUB_LOG")"
  elif [[ "$OUTPUT" != *"Ignoring the build in"*"The-Collective-9.9.9.zip is missing"* ]]; then
    fail "no reason for ignoring the build: $OUTPUT"
  else
    pass
  fi
}

case_spctl_fails() {
  current="a build Gatekeeper no longer accepts is rebuilt"
  new_repo spctl-fails
  declined_build || return 0
  local once="$TMP/spctl-fail-once"
  touch "$once"
  SPCTL_FAIL_ONCE="$once" run /dev/null publish --yes
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif ! logged "^xcodebuild "; then
    fail "no rebuild: $(cat "$STUB_LOG")"
  elif [[ "$OUTPUT" != *"Gatekeeper no longer accepts"* ]]; then
    fail "no reason for ignoring the build: $OUTPUT"
  elif ! released_on_origin; then
    fail "no release after the rebuild"
  else
    pass
  fi
}

case_yes_after_release_commit() {
  current="--yes also answers 'Release … from HEAD anyway?'"
  new_repo yes-anyway
  (cd "$REPO" && echo "later" >later.txt && git add later.txt &&
    git commit --quiet -m "fix: merged after the release PR" && git push --quiet origin main)
  run /dev/null publish --yes
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif [[ "$OUTPUT" != *"anyway? yes (--yes)"* ]]; then
    fail "the question is not answered with --yes: $OUTPUT"
  elif ! released_on_origin; then
    fail "no release"
  else
    pass
  fi
}

case_terminal_yes() {
  current="answering y in a terminal releases"
  new_repo terminal-yes
  run_in_terminal y publish
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif ! released_on_origin; then
    fail "no release: $OUTPUT"
  else
    pass
  fi
}

case_unknown_argument() {
  local args
  for args in "publish --bogus" "publish --yes extra" "deploy" ""; do
    current="'$args' prints the usage"
    new_repo "usage-${args// /-}"
    # shellcheck disable=SC2086 # the words are the arguments
    run /dev/null $args
    if [[ "$STATUS" -ne 2 ]]; then
      fail "exit status $STATUS, expected 2: $OUTPUT"
    elif [[ "$OUTPUT" != *"usage:"* || "$OUTPUT" != *"--yes"* ]]; then
      fail "no usage with --yes: $OUTPUT"
    elif [[ -s "$STUB_LOG" ]]; then
      fail "tools were called: $(cat "$STUB_LOG")"
    else
      pass
    fi
  done
}

case_publish_without_user_notes() {
  local variant
  for variant in "no file" "no section" "comment only" "blank only" "near-miss headings"; do
    current="publish stops before building with $variant in ReleaseNotes.md"
    new_repo "notes-${variant// /-}"
    case "$variant" in
      "no file") set_release_notes ;;
      "no section") set_release_notes $'# Release Notes\n\n## 9.9.8\n\nAn older release.\n' ;;
      "comment only") set_release_notes $'# Release Notes\n\n## 9.9.9\n\n<!-- a hint,\nover two lines -->\n\n<!-- another -->\n\n## 9.9.8\n\nAn older release.\n' ;;
      "blank only") set_release_notes $'# Release Notes\n\n## 9.9.9\n\n  \n\n## 9.9.8\n\nAn older release.\n' ;;
      # The heading must match the whole line literally: 9.9.90 and 9.9.9-rc1
      # are other versions, and `9.9.9` is no regex wildcard target either.
      "near-miss headings") set_release_notes $'# Release Notes\n\n## 9.9.90\n\nNot this one.\n\n## 9.9.9-rc1\n\nNor this one.\n' ;;
    esac
    run /dev/null publish --yes
    if [[ "$STATUS" -eq 0 ]]; then
      fail "exit status 0: $OUTPUT"
    elif [[ "$OUTPUT" != *"ReleaseNotes.md"* ]]; then
      fail "message does not name ReleaseNotes.md: $OUTPUT"
    elif logged "^xcodebuild " || logged "^gh "; then
      fail "built or released: $(cat "$STUB_LOG")"
    else
      pass
    fi
  done
}

# The app shows the bundled copy; a release whose copy lags behind the notes
# would ship without them.
case_publish_with_stale_bundled_copy() {
  local variant
  for variant in "an outdated" "no"; do
    current="publish stops before building with $variant bundled copy of ReleaseNotes.md"
    new_repo "stale-copy-${variant// /-}"
    (
      cd "$REPO"
      if [[ "$variant" == "no" ]]; then
        git rm --quiet "$BUNDLED_NOTES"
      else
        printf '# Release Notes\n' >"$BUNDLED_NOTES"
        git add "$BUNDLED_NOTES"
      fi
      git commit --quiet --amend --no-edit
      git push --quiet --force origin main
    )
    run /dev/null publish --yes
    if [[ "$STATUS" -eq 0 ]]; then
      fail "exit status 0: $OUTPUT"
    elif [[ "$OUTPUT" != *"cp ReleaseNotes.md $BUNDLED_NOTES"* ]]; then
      fail "message does not give the cp command: $OUTPUT"
    elif logged "^xcodebuild " || logged "^gh "; then
      fail "built or released: $(cat "$STUB_LOG")"
    else
      pass
    fi
  done
}

case_prepare_adds_user_notes_section() {
  current="prepare adds an empty ## 9.10.0 section to ReleaseNotes.md in the release commit"
  new_repo prepare-notes
  released_with_feature
  run /dev/null prepare --yes
  local notes
  notes="$(git -C "$REPO" show HEAD:ReleaseNotes.md 2>/dev/null || true)"
  # The new section sits between the header and 9.9.9 and holds only the hint.
  local expected=$'# Release Notes\n\nWritten by hand.\n\n## 9.10.0\n\n'
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif [[ "$(git -C "$REPO" log -1 --format=%s)" != "chore(release): v9.10.0" ]]; then
    fail "HEAD is not the release commit: $(git -C "$REPO" log -1 --format=%s)"
  elif ! git -C "$REPO" show --name-only --format= HEAD | grep -qx ReleaseNotes.md; then
    fail "the release commit does not change ReleaseNotes.md"
  elif [[ "$(git -C "$REPO" show "HEAD:$BUNDLED_NOTES" 2>/dev/null || true)" != "$notes" ]]; then
    fail "the bundled copy in the release commit is not ReleaseNotes.md: $(git -C "$REPO" show "HEAD:$BUNDLED_NOTES" 2>&1)"
  elif [[ "$notes" != "$expected<!-- "*" -->"$'\n\n'"## 9.9.9"$'\n\n'"The first test release." ]]; then
    fail "unexpected ReleaseNotes.md: $notes"
  elif [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
    fail "the working tree is not clean: $(git -C "$REPO" status --porcelain)"
  elif [[ "$(cat "$STUB_LOG")" != *"gh pr create "*"section of \`ReleaseNotes.md\` in this PR"* ]]; then
    fail "the PR body does not ask for the user notes: $(cat "$STUB_LOG")"
  elif [[ "$(cat "$STUB_LOG")" != *"gh pr create "*"cp ReleaseNotes.md $BUNDLED_NOTES"* ]]; then
    fail "the PR body does not say how to sync the bundled copy: $(cat "$STUB_LOG")"
  elif [[ "$OUTPUT" != *"ReleaseNotes.md"* ]]; then
    fail "the output does not ask for the user notes: $OUTPUT"
  else
    pass
  fi
}

# The state of ReleaseNotes.md before the first release with user notes.
case_prepare_first_user_notes_section() {
  current="prepare adds the first section below a ReleaseNotes.md header without sections"
  new_repo prepare-first-notes
  set_release_notes $'# Release Notes\n\nWritten by hand.\n'
  released_with_feature
  run /dev/null prepare --yes
  local notes
  notes="$(git -C "$REPO" show HEAD:ReleaseNotes.md 2>/dev/null || true)"
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif [[ "$notes" != $'# Release Notes\n\nWritten by hand.\n\n## 9.10.0\n\n<!-- '*' -->' ]]; then
    fail "unexpected ReleaseNotes.md: $notes"
  else
    pass
  fi
}

# Near-miss headings of the next version are other sections: prepare still
# adds its own.
case_prepare_ignores_near_miss_headings() {
  current="prepare adds ## 9.10.0 although ## 9.10.00 and ## 9.10.0-rc1 exist"
  new_repo prepare-near-miss
  set_release_notes $'# Release Notes\n\n## 9.10.00\n\nNot this one.\n\n## 9.10.0-rc1\n\nNor this one.\n'
  released_with_feature
  run /dev/null prepare --yes
  local notes
  notes="$(git -C "$REPO" show HEAD:ReleaseNotes.md 2>/dev/null || true)"
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif [[ "$notes" != $'# Release Notes\n\n## 9.10.0\n\n<!-- '*' -->'$'\n\n## 9.10.00\n\nNot this one.\n\n## 9.10.0-rc1\n\nNor this one.' ]]; then
    fail "unexpected ReleaseNotes.md: $notes"
  else
    pass
  fi
}

# A header that runs straight into the first section still gets exactly one
# blank line on each side of the new section.
case_prepare_header_without_blank_line() {
  current="prepare separates the new section by one blank line from a header without trailing blank line"
  new_repo prepare-tight-header
  set_release_notes $'# Release Notes\nWritten by hand.\n## 9.9.9\n\nThe first test release.\n'
  released_with_feature
  run /dev/null prepare --yes
  local notes
  notes="$(git -C "$REPO" show HEAD:ReleaseNotes.md 2>/dev/null || true)"
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif [[ "$notes" != $'# Release Notes\nWritten by hand.\n\n## 9.10.0\n\n<!-- '*' -->'$'\n\n## 9.9.9\n\nThe first test release.' ]]; then
    fail "unexpected ReleaseNotes.md: $notes"
  else
    pass
  fi
}

# Notes written ahead on main stay as they are, without a second heading.
case_prepare_keeps_written_user_notes() {
  current="prepare keeps a ## 9.10.0 section that is already written"
  new_repo prepare-written-notes
  local written=$'# Release Notes\n\nWritten by hand.\n\n## 9.10.0\n\nWritten ahead.\n\n## 9.9.9\n\nThe first test release.'
  set_release_notes "$written"$'\n'
  # Written ahead without syncing the copy: prepare brings it in step.
  (cd "$REPO" && printf '# Release Notes\n' >"$BUNDLED_NOTES" && git add "$BUNDLED_NOTES" &&
    git commit --quiet --amend --no-edit && git push --quiet --force origin main)
  released_with_feature
  run /dev/null prepare --yes
  local notes
  notes="$(git -C "$REPO" show HEAD:ReleaseNotes.md 2>/dev/null || true)"
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif [[ "$(git -C "$REPO" log -1 --format=%s)" != "chore(release): v9.10.0" ]]; then
    fail "HEAD is not the release commit: $(git -C "$REPO" log -1 --format=%s)"
  elif [[ "$notes" != "$written" ]]; then
    fail "ReleaseNotes.md changed: $notes"
  elif [[ "$(git -C "$REPO" show "HEAD:$BUNDLED_NOTES" 2>/dev/null || true)" != "$written" ]]; then
    fail "the bundled copy is not brought in step: $(git -C "$REPO" show "HEAD:$BUNDLED_NOTES" 2>&1)"
  elif [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
    fail "the working tree is not clean: $(git -C "$REPO" status --porcelain)"
  elif [[ "$(cat "$STUB_LOG")" != *"gh pr create "*"already in \`ReleaseNotes.md\`; review them in this PR"* ]]; then
    fail "the PR body does not ask to review the written notes: $(cat "$STUB_LOG")"
  elif [[ "$OUTPUT" != *"already in ReleaseNotes.md; review them in the release PR"* ]]; then
    fail "the output does not ask to review the written notes: $OUTPUT"
  else
    pass
  fi
}

case_prepare_without_user_notes() {
  current="prepare without ReleaseNotes.md stops before branching"
  new_repo prepare-no-notes
  set_release_notes
  released_with_feature
  run /dev/null prepare --yes
  if [[ "$STATUS" -eq 0 ]]; then
    fail "exit status 0: $OUTPUT"
  elif [[ "$OUTPUT" != *"ReleaseNotes.md"* ]]; then
    fail "message does not name ReleaseNotes.md: $OUTPUT"
  elif git -C "$REPO" show-ref --quiet --verify refs/heads/release/v9.10.0; then
    fail "branch release/v9.10.0 was created"
  else
    pass
  fi
}

# A pre-commit hook that refuses makes the release commit fail after every
# file was written, the latest point the undo has to cover.
case_prepare_failed_commit_restores_user_notes() {
  current="prepare whose commit fails restores ReleaseNotes.md and deletes the branch"
  new_repo prepare-undo
  released_with_feature
  printf '#!/bin/sh\nexit 1\n' >"$REPO/.git/hooks/pre-commit"
  chmod +x "$REPO/.git/hooks/pre-commit"
  run /dev/null prepare --yes
  if [[ "$STATUS" -eq 0 ]]; then
    fail "exit status 0: $OUTPUT"
  elif [[ "$(git -C "$REPO" symbolic-ref --short HEAD)" != "main" ]]; then
    fail "not back on main: $OUTPUT"
  elif [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
    fail "the working tree is not clean: $(git -C "$REPO" status --porcelain)"
  elif git -C "$REPO" show-ref --quiet --verify refs/heads/release/v9.10.0; then
    fail "branch release/v9.10.0 still exists"
  elif [[ "$OUTPUT" != *"Undoing: "*"ReleaseNotes.md"*"$BUNDLED_NOTES"* ]]; then
    fail "the undo message does not name ReleaseNotes.md and its bundled copy: $OUTPUT"
  else
    pass
  fi
}

# The zip is signed with sign_update from the build, the appcast is written
# from the version, signature, length and user notes, and both go up.
case_publish_first_appcast() {
  current="publish signs the zip and attaches a first appcast"
  new_repo publish-first-appcast
  run /dev/null publish --yes
  local zip="build/release/v9.9.9/The-Collective-9.9.9.zip" length
  length="$(stat -f %z "$REPO/$zip" 2>/dev/null || echo missing)"
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif ! logged "^sign_update $zip\$"; then
    fail "the zip was not signed: $(cat "$STUB_LOG")"
  elif ! logged "^swift run --quiet --package-path CollectiveKit -c release collective-appcast --version 9.9.9 --length $length --ed-signature c2lnbmF0dXJl --notes ReleaseNotes.md --output build/release/v9.9.9/appcast.xml\$"; then
    fail "collective-appcast did not get the signature, length and notes, or got a previous appcast: $(cat "$STUB_LOG")"
  elif logged "^gh release download"; then
    fail "there is no release to build on, yet one was downloaded: $(cat "$STUB_LOG")"
  elif ! logged "^gh release create v9.9.9 $zip build/release/v9.9.9/appcast.xml "; then
    fail "the appcast is not attached to the release: $(cat "$STUB_LOG")"
  else
    pass
  fi
}

case_publish_appcast_on_latest() {
  current="publish builds the appcast on the latest release's"
  new_repo publish-appcast-on-latest
  GH_LATEST=v9.9.8 run /dev/null publish --yes
  if [[ "$STATUS" -ne 0 ]]; then
    fail "exit status $STATUS: $OUTPUT"
  elif ! logged "^gh release download v9.9.8 --pattern appcast.xml --dir build/release/v9.9.9/previous\$"; then
    fail "the latest release's appcast was not downloaded: $(cat "$STUB_LOG")"
  elif ! logged "--previous build/release/v9.9.9/previous/appcast.xml --output"; then
    fail "collective-appcast did not get the previous appcast: $(cat "$STUB_LOG")"
  else
    pass
  fi
}

# Without the latest appcast, or without an answer from GitHub, the new one
# would drop every earlier version: nothing is tagged.
case_publish_without_previous_appcast() {
  current="publish stops when the latest release's appcast can't be had"
  local variant
  for variant in GH_NO_APPCAST GH_API_FAILS; do
    new_repo "publish-without-previous-$variant"
    if [[ "$variant" == GH_NO_APPCAST ]]; then
      GH_LATEST=v9.9.8 GH_NO_APPCAST=1 run /dev/null publish --yes
    else
      GH_API_FAILS=1 run /dev/null publish --yes
    fi
    if [[ "$STATUS" -eq 0 ]]; then
      fail "$variant: publish succeeded: $OUTPUT"
      return
    elif git -C "$ORIGIN" rev-parse --verify --quiet refs/tags/v9.9.9 >/dev/null || logged "^gh release create"; then
      fail "$variant: tagged or released anyway: $(cat "$STUB_LOG")"
      return
    fi
  done
  pass
}

make_stubs
case_no_terminal
case_publish_yes
case_publish_first_appcast
case_publish_appcast_on_latest
case_publish_without_previous_appcast
case_publish_notes_file
case_resume
case_other_sha
case_missing_zip
case_spctl_fails
case_yes_after_release_commit
case_terminal_yes
case_unknown_argument
case_publish_without_user_notes
case_publish_with_stale_bundled_copy
case_prepare_adds_user_notes_section
case_prepare_first_user_notes_section
case_prepare_ignores_near_miss_headings
case_prepare_header_without_blank_line
case_prepare_keeps_written_user_notes
case_prepare_without_user_notes
case_prepare_failed_commit_restores_user_notes

if [[ "$failures" -gt 0 ]]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
