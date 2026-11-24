#!/usr/bin/env bash
# Release flow for The Collective, in two steps so that every release goes
# through a pull request:
#
#   scripts/release.sh prepare   on main: next version, changelog section,
#                                empty user release notes section, release
#                                branch and PR (after a prompt)
#   scripts/release.sh publish   on main after the release PR was merged:
#                                notarized build, tag and GitHub release
#                                (after a prompt); run again, it reuses the
#                                notarized build of the same HEAD
#
# Both ask in the terminal; `--yes` (`-y`) after the command answers every
# question with yes. Without a terminal and without `--yes` they abort.
#
# Needs git-cliff, gh, Xcode, the notarytool keychain profile `notary` and,
# for publish, the Sparkle signing key in the keychain
# (see README).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

readonly VERSION_FILE="App/Version.xcconfig"
readonly CHANGELOG="CHANGELOG.md"
# The changelog lists every merged PR for developers; users get these notes,
# written by hand in the release PR.
readonly RELEASE_NOTES="ReleaseNotes.md"
# The copy the app bundles for its Release Notes sheet; `prepare` writes it,
# `publish` checks it.
readonly BUNDLED_RELEASE_NOTES="CollectiveKit/Sources/CollectiveKit/Resources/ReleaseNotes.md"
readonly RELEASE_NOTES_HINT="<!-- What changed for users of The Collective, in their words. Required: publish stops while this section is empty. -->"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: scripts/release.sh <command> [--yes]

  prepare   on main: compute the next version, write it, the changelog
            section and an empty section in ReleaseNotes.md on a new branch
            release/vX.Y.Z and open the release PR
  publish   on main after the release PR was merged: check that the
            ReleaseNotes.md section was written and the app's copy
            matches, build, notarize, tag
            vX.Y.Z and create the GitHub release; run again after a decline
            or failure, it reuses the notarized build of the same HEAD

  --yes, -y answer every question with yes (needed without a terminal)
EOF
  exit 2
}

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found; install it first (see README)"
  done
}

# Both steps work on exactly what is on origin/main: a release must never
# contain local edits or commits nobody else has seen.
require_clean_main() {
  [[ -z "$(git status --porcelain)" ]] ||
    die "the working tree is not clean (uncommitted or untracked files); commit or stash them first"

  local branch
  branch="$(git symbolic-ref --quiet --short HEAD || true)"
  [[ "$branch" == "main" ]] || die "not on main (current: ${branch:-detached HEAD}); run 'git switch main' first"

  git fetch --quiet origin main
  local counts ahead behind
  counts="$(git rev-list --left-right --count main...origin/main)"
  read -r ahead behind <<<"$counts"
  [[ "$behind" -eq 0 ]] || die "main is $behind commit(s) behind origin/main; run 'git pull' first"
  [[ "$ahead" -eq 0 ]] || die "main is $ahead commit(s) ahead of origin/main; releases only come from what is on origin"
}

local_tag_exists() {
  git rev-parse --quiet --verify "refs/tags/$1" >/dev/null
}

remote_tag_exists() {
  git ls-remote --exit-code --tags origin "refs/tags/$1" >/dev/null 2>&1
}

# Prints the body of the `## <version>` section of a Markdown file
# (CHANGELOG.md or ReleaseNotes.md), without surrounding blank lines.
markdown_section() {
  awk -v heading="## $2" '
    $0 == heading { found = 1; next }
    found && /^## / { exit }
    found { lines[++n] = $0 }
    END {
      first = 1; while (first <= n && lines[first] ~ /^[[:space:]]*$/) first++
      last = n; while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }
  ' "$1"
}

# Removes HTML comments from stdin, so the hint `prepare` leaves never reaches
# GitHub. An unclosed comment hides the rest when rendered, so it counts as
# comment up to the end.
strip_html_comments() {
  awk '
    { text = text $0 "\n" }
    END {
      while ((start = index(text, "<!--")) > 0) {
        rest = substr(text, start + 4)
        end = index(rest, "-->")
        if (end == 0) { text = substr(text, 1, start - 1); break }
        text = substr(text, 1, start - 1) substr(rest, end + 3)
      }
      printf "%s", text
    }
  '
}

# Succeeds when stdin holds more than HTML comments and whitespace: a section
# with only the hint is unwritten. No `grep -q`: its early exit could SIGPIPE
# the writer, which fails the pipeline under pipefail.
has_visible_text() {
  strip_html_comments | grep '[^[:space:]]' >/dev/null
}

# Puts an empty `## <version>` section with the hint above the newest
# section, so the header stays on top and older sections stay as they are.
add_release_notes_section() {
  local updated
  updated="$(awk -v heading="## $1" -v hint="$RELEASE_NOTES_HINT" '
    !done && /^## / {
      if (NR > 1 && last !~ /^[[:space:]]*$/) print ""
      print heading; print ""; print hint; print ""; done = 1
    }
    { print; last = $0 }
    END {
      if (done) exit
      if (NR > 0 && last !~ /^[[:space:]]*$/) print ""
      print heading; print ""; print hint
    }
  ' "$RELEASE_NOTES")"
  printf '%s\n' "$updated" >"$RELEASE_NOTES"
}

# git-cliff logs INFO and WARN lines (e.g. about skipped unconventional
# commits) that would bury the script's own output; errors still show.
cliff() {
  RUST_LOG=error git cliff "$@"
}

# Set by `--yes`: every question is answered with yes.
assume_yes=false

# Without a terminal `read` gets no answer, and a silent "no" once ended a
# publish after notarizing without tagging, with exit status 0.
require_answers() {
  "$assume_yes" || [[ -t 0 ]] ||
    die "release.sh asks for confirmation, but stdin is not a terminal; run it in a terminal or pass --yes"
}

confirm() {
  if "$assume_yes"; then
    echo "$1 yes (--yes)"
    return 0
  fi
  require_answers
  local answer=""
  read -r -p "$1 [y/N] " answer || true
  [[ "$answer" == [yY] ]]
}

# The release branch `prepare` created but has not committed to yet.
pending_branch=""

# EXIT trap while `pending_branch` is set: restores the four files, returns
# to main and deletes the branch, so a failed `prepare` can simply be rerun.
undo_pending_branch() {
  [[ -n "$pending_branch" ]] || return 0
  echo "Undoing: restoring $VERSION_FILE, $CHANGELOG, $RELEASE_NOTES and $BUNDLED_RELEASE_NOTES, deleting branch $pending_branch" >&2
  if git checkout --quiet main -- "$VERSION_FILE" "$CHANGELOG" "$RELEASE_NOTES" "$BUNDLED_RELEASE_NOTES" &&
    git switch --quiet main &&
    git branch --quiet -D "$pending_branch"; then
    return 0
  fi
  echo "error: could not undo; check 'git status', then: git switch main && git branch -D $pending_branch" >&2
}

cmd_prepare() {
  require_tools git-cliff gh
  require_clean_main
  # Without the file there is no place for the user notes, and `publish`
  # would stop later anyway.
  [[ -f "$RELEASE_NOTES" ]] || die "$RELEASE_NOTES is missing; restore it on main first (see README › Releasing)"

  # The same rule as `tag_pattern` in cliff.toml, so that the script and
  # git-cliff agree on the base: a glob would also take e.g. v1.2.0-rc1.
  local latest
  latest="$(git tag --merged HEAD --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
  # Without a release tag git-cliff would put the whole history into the new
  # section; v1.0.0 comes from `publish` alone.
  [[ -n "$latest" ]] || die "no release tag vX.Y.Z yet; publish the current version first"

  local tag version branch
  tag="$(cliff --bumped-version)"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "git cliff returned an unexpected version: '$tag'"
  [[ "$tag" != "$latest" ]] || die "nothing to release: no conventional commits since $latest"
  version="${tag#v}"
  branch="release/$tag"

  git show-ref --quiet --verify "refs/heads/$branch" && die "branch $branch already exists locally"
  git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 && die "branch $branch already exists on origin"
  local_tag_exists "$tag" && die "tag $tag already exists locally"
  remote_tag_exists "$tag" && die "tag $tag already exists on origin"

  echo "Preparing $tag (last release: $latest)"
  git switch --quiet -c "$branch"
  # Any failure until the commit exists puts the repo back on a clean main.
  pending_branch="$branch"
  trap undo_pending_branch EXIT

  sed -i '' -E "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $version/" "$VERSION_FILE"
  grep -qx "MARKETING_VERSION = $version" "$VERSION_FILE" ||
    die "could not set MARKETING_VERSION in $VERSION_FILE"

  # Prepending keeps the older sections as they are, including hand edits.
  cliff --unreleased --tag "$tag" --prepend "$CHANGELOG"
  # Notes written ahead on main stay as they are; a second, empty heading
  # above them would be the one `publish` reads.
  local notes_hint notes_pr_hint
  if grep -qxF "## $version" "$RELEASE_NOTES"; then
    notes_hint="The user release notes for $version are already in $RELEASE_NOTES; review them in the release PR."
    notes_pr_hint="The user release notes for $version are already in \`$RELEASE_NOTES\`; review them in this PR."
  else
    add_release_notes_section "$version"
    notes_hint="Write the user release notes in the '## $version' section of $RELEASE_NOTES in the release PR; publish stops while it is empty."
    notes_pr_hint="Write the user release notes in the \`## $version\` section of \`$RELEASE_NOTES\` in this PR, in words for users of The Collective. \`scripts/release.sh publish\` stops while that section is empty."
  fi

  # Also when the section was already there: notes written ahead on main may
  # not have reached the copy.
  cp "$RELEASE_NOTES" "$BUNDLED_RELEASE_NOTES"

  git add -- "$VERSION_FILE" "$CHANGELOG" "$RELEASE_NOTES" "$BUNDLED_RELEASE_NOTES"
  git commit --quiet -m "chore(release): $tag"
  trap - EXIT
  pending_branch=""

  local notes
  notes="$(markdown_section "$CHANGELOG" "$version")"
  echo
  echo "Committed chore(release): $tag on $branch with this changelog section:"
  echo
  echo "$notes"
  echo
  echo "$notes_hint"
  echo

  if ! confirm "Push $branch and open the release PR?"; then
    cat <<EOF

Nothing was pushed. The release commit is on the local branch $branch.
To continue:  git push -u origin $branch && gh pr create --base main --head $branch --title "chore(release): $tag"
To undo:      git switch main && git branch -D $branch
EOF
    return
  fi

  git push --quiet -u origin "$branch"
  gh pr create --base main --head "$branch" --title "chore(release): $tag" --body "$(
    cat <<EOF
$notes

---

This section is in \`$CHANGELOG\`; edit it in this PR if needed. After the squash-merge, \`scripts/release.sh publish\` on \`main\` uses it as the release notes.

$notes_pr_hint The app bundles a copy: after editing, run \`cp $RELEASE_NOTES $BUNDLED_RELEASE_NOTES\` and commit both; \`publish\` stops while they differ.
EOF
  )"

  echo
  echo "After the PR is merged: git switch main && git pull && scripts/release.sh publish"
}

# Archives, signs, notarizes, staples and zips the app into a fresh $out.
# Writing the marker last means it only exists for a complete build.
build_notarized() {
  local version="$1" out="$2" app="$3" zip="$4"
  # Start from scratch so nothing from an earlier, failed run ends up in the build.
  rm -rf "$out"
  mkdir -p "$out"

  echo "Building The Collective $version into $out"
  xcodebuild -quiet -project App/Collective.xcodeproj -scheme Collective -configuration Release \
    -derivedDataPath "$out/DerivedData" -archivePath "$out/Collective.xcarchive" archive
  xcodebuild -quiet -exportArchive -archivePath "$out/Collective.xcarchive" \
    -exportOptionsPlist App/ExportOptions.plist -exportPath "$out/export"

  local built
  built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  [[ "$built" == "$version" ]] || die "the built app has version $built, expected $version"

  echo "Notarizing (this takes a few minutes)"
  ditto -c -k --keepParent "$app" "$out/upload.zip"
  # notarytool can exit 0 even when Apple rejects the upload, so the verdict
  # is read from its output.
  xcrun notarytool submit "$out/upload.zip" --keychain-profile notary --wait 2>&1 |
    tee "$out/notarize.log" || true
  if ! grep -Eq '^[[:space:]]*status: Accepted' "$out/notarize.log"; then
    local id
    id="$(awk '/^[[:space:]]*id:/ { print $2; exit }' "$out/notarize.log")"
    die "notarization was not accepted; see: xcrun notarytool log ${id:-<submission id>} --keychain-profile notary"
  fi

  xcrun stapler staple "$app"
  local assessment
  assessment="$(spctl -a -vv "$app" 2>&1 || true)"
  echo "$assessment"
  grep -q 'source=Notarized Developer ID' <<<"$assessment" ||
    die "Gatekeeper does not accept the stapled app as notarized"

  ditto -c -k --keepParent "$app" "$zip"
  git rev-parse HEAD >"$out/notarized-commit"
}

# Sparkle's tools come with the package in the build's DerivedData.
readonly SPARKLE_BIN="SourcePackages/artifacts/sparkle/Sparkle/bin"

# Prints "<EdDSA signature> <length>" of the zip. sign_update reads the
# private key from the maintainer's keychain (README › Releasing); macOS may
# ask to allow it.
sign_archive() {
  local out="$1" zip="$2"
  local tool="$out/DerivedData/$SPARKLE_BIN/sign_update" line
  [[ -x "$tool" ]] || die "Sparkle's sign_update is missing in $out/DerivedData; delete $out and run publish again"
  line="$("$tool" "$zip")" || die "sign_update failed; is the Sparkle key in this Mac's keychain? (README › Releasing)"
  [[ "$line" =~ sparkle:edSignature=\"([^\"]+)\"\ length=\"([0-9]+)\" ]] ||
    die "unexpected output of sign_update: $line"
  printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# The tag of the latest GitHub release, empty when there is none yet. Any
# other failure stops: a fresh appcast would drop every earlier version.
latest_release_tag() {
  local output
  if output="$(gh api 'repos/{owner}/{repo}/releases/latest' --jq .tag_name 2>&1)"; then
    printf '%s\n' "$output"
  elif [[ "$output" != *"HTTP 404"* ]]; then
    die "could not ask GitHub for the latest release: $output"
  fi
}

# Writes $out/appcast.xml: the latest release's appcast with this version on
# top, its notes from $RELEASE_NOTES. The app reads it from
# releases/latest/download/appcast.xml, so every release carries all versions.
write_appcast() {
  local version="$1" out="$2" signature="$3" length="$4"
  local latest previous=()
  latest="$(latest_release_tag)"
  rm -rf "$out/previous"
  if [[ -n "$latest" ]]; then
    mkdir -p "$out/previous"
    gh release download "$latest" --pattern appcast.xml --dir "$out/previous" ||
      die "release $latest has no appcast.xml to build on; attach the last one before publishing"
    previous=(--previous "$out/previous/appcast.xml")
  fi
  swift run --quiet --package-path CollectiveKit -c release collective-appcast \
    --version "$version" --length "$length" --ed-signature "$signature" \
    --notes "$RELEASE_NOTES" ${previous[@]+"${previous[@]}"} --output "$out/appcast.xml" ||
    die "could not write the appcast"
}

# Building and notarizing takes about ten minutes; a run that got that far
# but not to the tag (declined or interrupted) can be continued with its
# build, as long as it is of the same commit and Gatekeeper still accepts it.
reusable_build() {
  local out="$1" app="$2" zip="$3"
  [[ -f "$out/notarized-commit" ]] || return 1

  local marked
  marked="$(<"$out/notarized-commit")"
  if [[ "$marked" != "$(git rev-parse HEAD)" ]]; then
    echo "Ignoring the build in $out: it was notarized for ${marked:0:7}, not for HEAD"
    return 1
  fi
  if [[ ! -f "$zip" ]]; then
    echo "Ignoring the build in $out: $zip is missing"
    return 1
  fi
  local assessment
  assessment="$(spctl -a -vv "$app" 2>&1 || true)"
  if ! grep -q 'source=Notarized Developer ID' <<<"$assessment"; then
    echo "Ignoring the build in $out: Gatekeeper no longer accepts the app as notarized"
    return 1
  fi
}

cmd_publish() {
  require_tools gh xcodebuild xcrun swift
  require_clean_main

  local version tag
  version="$(sed -n -E 's/^MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' "$VERSION_FILE")"
  [[ -n "$version" ]] || die "no line 'MARKETING_VERSION = X.Y.Z' in $VERSION_FILE"
  tag="v$version"

  local_tag_exists "$tag" && die "tag $tag already exists locally; $version is already released"
  remote_tag_exists "$tag" && die "tag $tag already exists on origin; $version is already released"

  local notes
  notes="$(markdown_section "$CHANGELOG" "$version")"
  [[ -n "$notes" ]] || die "$CHANGELOG has no '## $version' section, or it is empty"

  # Checked before building, so forgotten user notes cost no notarization.
  [[ -f "$RELEASE_NOTES" ]] || die "$RELEASE_NOTES is missing; it needs a '## $version' section with the user release notes"
  grep -qxF "## $version" "$RELEASE_NOTES" ||
    die "$RELEASE_NOTES has no '## $version' section; write the user release notes there in a PR first"
  markdown_section "$RELEASE_NOTES" "$version" | has_visible_text ||
    die "the '## $version' section of $RELEASE_NOTES is empty (only comments or blank lines); write the user release notes there in a PR first"
  # The app shows its bundled copy; a stale one would ship without these notes.
  cmp -s "$RELEASE_NOTES" "$BUNDLED_RELEASE_NOTES" ||
    die "$BUNDLED_RELEASE_NOTES differs from $RELEASE_NOTES (or is missing); in a PR run: cp $RELEASE_NOTES $BUNDLED_RELEASE_NOTES"

  # The tag goes on HEAD; a PR merged after the release PR would end up in
  # this release without being in its changelog section.
  local release_commit
  release_commit="$(git log -1 --format=%H -- "$VERSION_FILE")"
  if [[ "$release_commit" != "$(git rev-parse HEAD)" ]]; then
    echo "HEAD is not the last commit that changed $VERSION_FILE ($(git rev-parse --short "$release_commit")); merged since:"
    git --no-pager log --oneline "$release_commit..HEAD"
    confirm "Release $version from HEAD ($(git rev-parse --short HEAD)) anyway?" ||
      die "aborted; nothing was built"
  fi

  local out="build/release/$tag"
  local app="$out/export/The Collective.app"
  local zip="$out/The-Collective-$version.zip"
  if reusable_build "$out" "$app" "$zip"; then
    echo "Reusing the notarized build from $(git rev-parse --short HEAD) in $out"
  else
    build_notarized "$version" "$out" "$app" "$zip"
  fi
  local signature length
  read -r signature length <<<"$(sign_archive "$out" "$zip")"
  write_appcast "$version" "$out" "$signature" "$length"

  # User notes on top, the developer changelog below; the blank lines the
  # stripped comments leave behind are squeezed and trimmed.
  local user_notes
  user_notes="$(markdown_section "$RELEASE_NOTES" "$version" | strip_html_comments | cat -s | sed '/./,$!d')"
  printf '%s\n\n---\n\n### Changes\n\n%s\n' "$user_notes" "$notes" >"$out/notes.md"

  echo
  echo "Notarized build: $zip"
  echo "Appcast:         $out/appcast.xml"
  echo
  echo "Release notes (from $RELEASE_NOTES and $CHANGELOG):"
  echo
  cat "$out/notes.md"
  echo

  if ! confirm "Tag $tag on $(git rev-parse --short HEAD), push the tag and create the GitHub release?"; then
    cat <<EOF

Nothing was tagged or pushed. The notarized build stays in $out.
To continue:  git tag -a $tag -m "The Collective $version" && git push origin $tag \\
                && gh release create $tag "$zip" "$out/appcast.xml" --verify-tag --title "The Collective $version" --notes-file "$out/notes.md"
Or run scripts/release.sh publish again; it reuses this notarized build as long as HEAD stays $(git rev-parse --short HEAD).
EOF
    return
  fi

  git tag -a "$tag" -m "The Collective $version"
  git push --quiet origin "$tag"
  gh release create "$tag" "$zip" "$out/appcast.xml" --verify-tag --title "The Collective $version" --notes-file "$out/notes.md"
}

[[ $# -ge 1 ]] || usage
subcommand="$1"
shift
if [[ $# -gt 0 ]]; then
  case "$1" in
    --yes | -y) assume_yes=true ;;
    *) usage ;;
  esac
  shift
fi
[[ $# -eq 0 ]] || usage

case "$subcommand" in
  prepare | publish) ;;
  *) usage ;;
esac
# Before fetching or building, so a run that could never be confirmed stops
# right away instead of after ten minutes of notarizing.
require_answers
"cmd_$subcommand"
