# Using MutantKit with coding agents

MutantKit ships a ready-to-use skill file at
[`skills/mutantkit/SKILL.md`](../skills/mutantkit/SKILL.md) — practical
operating knowledge for an agent driving the CLI: setup-first discipline,
how to read `integrity` before trusting a score, how to tell a real
survivor from an unkillable OS/hardware boundary, the suppression and
CI-gate patterns, and what not to do (report a score without checking
integrity, run unbudgeted before `setup`, hand-edit `plan.json`). Point an
agent at it instead of re-deriving MutantKit's CLI surface from `--help`
output every session.

## Claude Code — install as a plugin (recommended)

This repo is itself a self-hosted plugin marketplace
([`.claude-plugin/marketplace.json`](../.claude-plugin/marketplace.json)) for a
single plugin ([`.claude-plugin/plugin.json`](../.claude-plugin/plugin.json))
that wraps the same `skills/mutantkit/SKILL.md` — no separate copy of the
skill is maintained. Add the marketplace once, then install:

```bash
claude plugin marketplace add juntaki/mutantkit
claude plugin install mutantkit@mutantkit
```

or, from inside an interactive session:

```
/plugin marketplace add juntaki/mutantkit
/plugin install mutantkit@mutantkit
```

This gets you the skill plus automatic updates (`claude plugin marketplace
update mutantkit` / `claude plugin update mutantkit`) through Claude Code's
normal plugin lifecycle, without hand-copying a file. (This is unrelated to
`claude plugin init`, which scaffolds a brand-new personal plugin under
`~/.claude/skills/` — that command is for authoring a plugin from scratch,
not for installing this one.)

## Claude Code — manual fallback

Skills are also auto-discovered from `.claude/skills/<name>/SKILL.md`
directly, with no plugin involved. Use this if you'd rather not add a
marketplace — e.g. a one-off personal copy, or a locally-edited variant:

```bash
# personal — available in every project
mkdir -p ~/.claude/skills/mutantkit
cp skills/mutantkit/SKILL.md ~/.claude/skills/mutantkit/SKILL.md

# project-scoped — this repo only, commit it if the whole team should have it
mkdir -p .claude/skills/mutantkit
cp skills/mutantkit/SKILL.md .claude/skills/mutantkit/SKILL.md
```

## Codex — plugin (recommended)

This repo is also a self-hosted Codex plugin marketplace
([`.agents/plugins/marketplace.json`](../.agents/plugins/marketplace.json)) for
a single plugin ([`.codex-plugin/plugin.json`](../.codex-plugin/plugin.json))
whose `skills` field points at the same `./skills/` directory used above, so
there is still only one copy of `SKILL.md`. Add the marketplace once, then
install:

```bash
codex plugin marketplace add juntaki/mutantkit
codex plugin add mutantkit@mutantkit
```

`codex plugin marketplace add` accepts the `owner/repo` GitHub shorthand
shown above (also a git URL or a local path); `codex plugin add
<plugin>@<marketplace>` is the CLI verb that installs and enables a plugin
from an already-added marketplace — both are real CLI commands, not a
desktop-app-only action. (`codex plugin marketplace list` / `upgrade` /
`remove` manage sources the same way `claude plugin marketplace` does, and
`codex plugin list` / `remove` mirror `codex plugin add` for the plugin
itself.)

## Codex CLI — manual fallback (`AGENTS.md`)

Codex also reads `AGENTS.md` automatically from the project root (and parent
directories), independent of the plugin system above. Fold the skill's
contents in directly, or keep it as a separate file and reference it:

```bash
mkdir -p .codex   # if you keep project-local Codex config here
cat skills/mutantkit/SKILL.md >> AGENTS.md
# or, to keep it separate and just point Codex at it:
echo "See skills/mutantkit/SKILL.md for MutantKit usage." >> AGENTS.md
```

The file itself has no Claude- or Codex-specific syntax beyond the YAML
frontmatter Claude Code's skill loader reads (`name`/`description`) — the
body is plain instructions any agent can follow, so copying it into
whichever context file your tool of choice loads (`AGENTS.md`, a custom
system prompt, an MCP resource) works the same way.
