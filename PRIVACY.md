# Privacy

The Collective is a macOS menu bar app that runs entirely on your own computer. It has no account, no telemetry, no analytics and no crash reporting. Neither the author nor anyone else receives data from it. The one exception is the update check described under [Network access](#network-access): it asks GitHub for public release tags and sends nothing about you or your sessions.

## What the app reads

- **The subspace event files.** The [subspace](https://github.com/we-are-the-borg/subspace) plugins write every hook event of Claude Code and Codex as a file into their plugin data folders (`~/.claude/plugins/data/subspace-subspace/` and `~/.codex/plugins/data/subspace-subspace/`, or the equivalent under `CLAUDE_CONFIG_DIR` / `CODEX_HOME`). These events can contain your prompts, the agents' replies, their tool calls with input and output (for example commands, file paths and file contents), session identifiers and which terminal a session runs in. See [subspace's privacy policy](https://github.com/we-are-the-borg/subspace/blob/main/PRIVACY.md) for what the plugins record.
- **Files the agents keep themselves,** for details the events don't carry: Claude Code's session status files (`~/.claude/sessions/`) and subagent metadata (`agent-<id>.meta.json`), and the first line and turn settings of a Codex session's rollout file.
- **The agents' plugin configuration,** to show in Setup and Settings whether subspace is installed and enabled: Claude Code's `settings.json` and `plugins/installed_plugins.json`, and the output of `--version`, `plugin list` and `plugin marketplace list` of the `claude` and `codex` command lines, which the app runs for that purpose.
- **Process information** of the agents' processes (whether a process still runs and when it started), so a session whose agent has quit is shown as ended.

The app only reads these files. It never changes or deletes them.

## What the app stores

All of it stays on your computer, readable by your user account:

- **The event store,** an SQLite database in the app's folder in `~/Library/Application Support/`. It keeps the events the app has read, so that sessions survive a restart of the app after subspace has deleted its files. Events older than the retention period are deleted: 3 days by default, adjustable in Settings › Sessions to 1 day, 1 week or unlimited. Settings › Sessions also clears all stored events.
- **Your settings** in the app's preferences (`UserDefaults`): retention, notifications, appearance, the chosen subspace folders, and the time and result of the last update check.
- **Custom color schemes** you add, in `~/Library/Application Support/The Collective/Themes/`.

Deleting the app's folder in `~/Library/Application Support/` and its preferences removes everything the app has stored.

## Notifications

When enabled, the app shows macOS notifications when an agent needs permission, asks a question or finishes a turn. They show the session's name and agent (Claude Code or Codex) and, depending on the kind, the tool and command waiting for permission, the question with its options, or the start of the reply. They are local notifications, handled by macOS like those of any other app.

## Network access

- **subspace update check.** When "Check for subspace updates" is on (the default), the app asks GitHub's public API for the release tags of the subspace plugin repositories (`api.github.com/repos/we-are-the-borg/subspace-claude-code/tags` and `…/subspace-codex/tags`): at launch at most once a day, and when you open Setup or a source's settings at most once an hour. The request carries no cookies, credentials or identifiers of yours, only the app's name as User-Agent, and nothing is cached. Like any web request it reaches GitHub with your IP address; GitHub's [privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement) covers how GitHub handles that. Turn the switch off in Settings and the app asks GitHub nothing.
- **Commands you start.** Setup and Settings offer to install, enable or update the subspace plugins. When you click one of these, the app runs the agent's own command line (for example `claude plugin install …`) in your login shell. That command downloads the plugin from GitHub under the agent's own terms. The app runs none of these on its own.
- **Links.** Links in the app (release notes, documentation, the subspace repository, links in agent replies) open in your browser only when you click them.

The app sends no event data, prompts, replies, file paths or settings anywhere.

## The agents themselves

Claude Code and Codex process your data under their own terms and privacy policies (Anthropic, OpenAI). The Collective only shows what they and subspace have already written to your disk, and does not change what the agents collect or send.

## Contact

Questions about this policy: open an issue at <https://github.com/we-are-the-borg/collective/issues>. For security problems see [`SECURITY.md`](SECURITY.md).
