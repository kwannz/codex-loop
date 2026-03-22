# codex-loop

Opus↔Codex multi-agent skill for Claude Code. Opus explores and plans, Codex agents execute in parallel.

## Features

- **Ralph mode** (`-ralph`): Multi-story parallel dispatch with iterative feedback loop
- **Research mode** (`-research`): Autonomous keep/discard exploration loop
- **Write isolation**: `write_root` scope enforcement per agent from `scope:` line
- **PUA-inspired prompts**: Anti-laziness, failure escalation L0-L4, three red lines
- **All on main**: No branches, no worktrees

## Usage

```bash
# Opus writes story prompts to state/outputs/, then:
codex-loop.sh -ralph -auto-max 10

# Single dispatch (Opus orchestrates multiple in parallel):
codex-loop.sh -dispatch -prompt-file story.md -output result.md

# Research mode:
codex-loop.sh -research "explore direction" 5

# Utilities:
codex-loop.sh -scan      # Codebase scan
codex-loop.sh -status    # Show session
codex-loop.sh -cancel    # Cancel active loop
```

## Architecture

```
Opus (explorer/planner)
  ├─ scan codebase
  ├─ decompose into stories (disjoint scope)
  ├─ write precise prompts → state/outputs/*.md
  └─ invoke: codex-loop.sh -ralph
       ├─ parallel codex exec × N agents
       ├─ wait all → cargo check/test
       ├─ PASS → commit → done
       └─ FAIL → write _feedback.md → retry
           └─ 3 consecutive fails → stop

Codex (pure executor)
  ├─ implement exactly as planned
  ├─ no exploration, no refactoring
  └─ report exact verification output
```

## Install

Copy `skills/codex-loop/` into your project, or symlink to `.claude/skills/codex-loop/`.

## License

MIT
