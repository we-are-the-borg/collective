# Release Notes

Handwritten changelog and release notes for each version of The Collective. See the full list of changes in [`CHANGELOG.md`](CHANGELOG.md).

## 1.2.0

- Redesigned the app with a new look, IBM Plex type and new icons.
- Added an Appearance pane with 38 color schemes across 14 families. Light and dark mode can use separate schemes or share one.
- Added support for importing base16 and base24 schemes from `tinted-theming` (https://github.com/tinted-theming).
- About now lists the licenses for the libraries, fonts, icons and color schemes used by the app.
- Removed the running indicator from active session cards. Their borders no longer animate.

## 1.1.0

- Added menu bar animation settings. Choose between fancy and performant.
- Session cards now show reasoning effort alongside the model. Effort colors can be disabled in Settings › General.
- Fixed Codex sessions incorrectly showing as waiting for approval when automatic review handles the request.
- Significantly reduced CPU usage of the menu bar icon, particularly during animations.

## 1.0.0

Initial release of **The Collective**, a menu bar app for monitoring AI coding agents like Claude Code and Codex.

- Shows the number of active sessions, including subagents, and indicates when a session needs attention.
- Lists sessions with their prompts, current tools, runtime, latest replies and subagents.
- Sends notifications for permission requests, questions and completed long-running turns.
- Provides quick access to a session's terminal and lets you copy its path.
- Includes guided setup for installing **subspace** and checking for updates.