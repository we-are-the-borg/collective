# Changelog

All notable changes to The Collective. Versions follow [Semantic Versioning](https://semver.org);
each section lists the merged pull requests by type.

<!-- git-cliff: end of header -->

## 1.4.0

### Features

- **antigravity:** Add Google Antigravity as a subspace source (#27)
- **setup:** Support installing Antigravity plugin without agy CLI (#30)

### Bug Fixes

- **setup:** Update each source's status as soon as its probe finishes (#29)

## 1.3.0

### Features

- **updates:** Update the app with Sparkle
- **updates:** Sign releases for Sparkle and publish appcast
- **claude-code:** Show the whole command of a permission request from the mapped command field
- **settings:** Read the release notes in a sheet from About
- **release:** Hand-written user release notes in ReleaseNotes.md
- **popover:** Mark sessions with an unread reply
- **popover:** Jump to the session's app with a button in the last line, not the whole row
- **popover:** Read the whole reply in a card that "Show more" opens
- **settings:** Control borders and accent states from the theme roles, quieter popover frame
- **release:** Resume publish from the notarized build, add --yes, never a silent no

### Bug Fixes

- **popover:** Resting sessions stay idle when the popover opens while the backlog is read
- **popover:** Idle preview opens under the reply text, not under the whole card
- **popover:** Emphasis in replies is italic again
- **claude-code:** Resumed and interrupted subagents no longer leave the session "waiting for you"
- **popover:** Draw the shadow on a sublayer AppKit leaves alone

### Performance

- **popover:** Keep the working halo still
- **claude-code:** Name models without compiling a regex per call
- **spool:** Watch the spool with file events

### Refactoring

- **kit:** Move SubspaceKit into the repo as a local package

### Documentation

- Add privacy policy
- Add the MIT licence and a README for users
- Add dark screenshots to the README
- English CLAUDE.md and links for the public repository
- **kit:** Drop planning references from comments

### Tests

- **codex:** Back the whole-command box with a real multi-line capture
- **kit:** Carry only scrubbed fixtures the tests read

### CI

- Run tests, the privacy check and the PR title lint on every PR

### Chores

- **kit:** Drop private paths and names from code and tests
- **scripts:** Add a check for private data before going public

## 1.2.0

### Features

- **popover:** Keep the working card's border still
- **kit:** Theme module with base16/base24 schemes and roles like Unimatrix Zero
- **kit:** Theme roles, IBM Plex and Lucide in CollectiveUI
- **popover:** Restyle the popover in the Unimatrix Zero look
- **settings:** Settings, setup and About in the Unimatrix look, pane Appearance
- **kit:** Theme module on Unimatrix Zero 43f1307, sidebar on the panel surface
- **settings:** More schemes, custom themes and the Appearance pane with search

### Documentation

- **tasks:** Plan the open-source go-live in phases
- **tasks:** Tick the effort level and working border visual checks
- **tasks:** Plan the restyling in the Unimatrix Zero look
- **design:** Adopt the Unimatrix-style popover design
- **design:** Adopt the Unimatrix-style settings, setup and About design
- **design:** Adopt the themes design
- **design:** Re-measure the theme findings against Unimatrix 3c565f9
- **todo:** Link the Unimatrix theme requests

### Tests

- **kit:** Keep the suite stable under parallel load

## 1.1.0

### Features

- **settings:** Choose when and how fast the menu bar cube animates
- **popover:** Show the effort level next to the model

### Bug Fixes

- **release:** List the commits since the release commit without a pager
- **codex:** Don't show approvals the automatic reviewer answers as waiting
- **menubar:** Draw the status item image only on a new frame or a real appearance change

### Performance

- **menubar:** Keep the window opener out of the status item button

### Documentation

- **tasks:** Add the subspace links next to the About licenses
- **tasks:** Tick the menu bar animation visual check

## 1.0.0

Initial release.
