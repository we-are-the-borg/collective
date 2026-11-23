# Contributing

Thanks for helping. The Collective is a small macOS menu bar app that shows running coding agents; the hooks that feed it live in [subspace](https://github.com/we-are-the-borg/subspace).

- **Read [`CLAUDE.md`](CLAUDE.md) first.** It holds the rules for humans and coding agents alike: where things live, the architecture rules (tool-neutral core, adapters only through the subspace mapping, theme roles only) and the commands.
- **Open an issue first** for anything bigger than a small fix, so we can agree on the approach before you build it.
- **Pull requests** go against `main` and are squash-merged. The PR title becomes the commit message and drives the version and changelog, so it follows [Conventional Commits](https://www.conventionalcommits.org/): `feat: …`, `fix: …`, `docs: …`, `chore: …`, with a scope where it helps (`feat(popover): …`). Never bump versions by hand; releases are made with `scripts/release.sh` (README › Releasing).
- **Tests:** `swift test` in `CollectiveKit/` and `SubspaceKit/`. Some tests need a checkout of subspace next to this one (`../subspace` inside a `we-are-the-borg/` folder) or `SUBSPACE_DEV_DIR`; without it they are skipped. CI runs them on macOS.
- **Adapters are tested against real, captured payloads only.** Fixtures are public: no home paths, names, account identifiers, prompts or replies of your own. `scripts/public-check.sh` must report nothing.
- **Events and fields** come from subspace. If the app needs something subspace doesn't deliver, open an issue there, not a workaround here.

Security problems: see [`SECURITY.md`](SECURITY.md).
