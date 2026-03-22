---
name: codex-loop
description: "Opus↔Codex multi-agent. NEVER STOP. NEVER ASK. Opus 直接编排多 Codex agent 并行执行。All on main — no branches."
argument-hint: '"task description" or -research "direction" [N]'
allowed-tools: Bash(*), Read, Write, Edit, Grep, Glob, Agent(*)
---

# Codex Loop

`/codex-loop $ARGUMENTS`

**Opus = 探索者/规划者。Codex = 纯执行者。** NEVER STOP. NEVER ASK. 禁止分支，直接 main。

## Core Flow

```
Opus 探索/规划 → 写精准 prompt → -ralph 自动循环(多 Codex agent 并行执行)
  → verify → PASS: commit → Opus 规划下一批
  → FAIL: 脚本写富 feedback → Codex 下轮按修正计划重做
  → 3 consecutive fails: 返回 Opus 重新探索方向
```

## Opus 编排协议 (DEFAULT: -ralph)

```python
# ── Phase 0: Opus 探索 ──
Bash(f"{skill_dir}/scripts/codex-loop.sh -scan")
# Opus 读源码、理解架构、探索方向
for file in relevant_files:
    Bash(f"cat {file}")  # Opus 读源码

# ── Phase 1: Opus 分解 story ──
stories = decompose(task)  # disjoint scope, bottom-up DAG
for story in stories:
    source = Bash(f"cat {' '.join(story.scope)}")  # 读相关源码
    # Opus 写精准 prompt（Context + Requirement + Plan + Constraints）
    Write(f"state/outputs/story-{story.id}.md", build_precise_prompt(story, source))

# ── Phase 2: -ralph 自动循环 ──
# 脚本接管: 并行 dispatch → verify → feedback → retry
Bash(f"{skill_dir}/scripts/codex-loop.sh -ralph -auto-max 10",
     run_in_background=True)
# 循环内 Codex 是纯执行者 — 按 Opus 的 plan 精确实现
# 失败时脚本自动生成富 feedback（agent 结果 + 完整错误 + diff stat）
# Codex 下轮读 feedback 按修正方向重做

# ── Phase 3: Opus 审核结果 ──
# -ralph 返回后，Opus 读 outputs, 验证, 决定下一步
Bash("cat state/outputs/*-output.md")
Bash("cargo check --workspace && cargo test --workspace")
# 如果需要新方向 → 回到 Phase 0 重新探索
```

**角色分工**:
- **Opus**: 探索方向、读源码、分解 story、写精准 plan、审核结果、调整策略
- **Codex**: 按 plan 精确执行、报告结果、不探索不重构不超出 scope

## Script Commands (helper functions for Opus)

```bash
codex-loop.sh -scan                  # Codebase scan → state/scan-results.md
codex-loop.sh -dispatch -prompt-file FILE -output FILE  # Single codex exec
codex-loop.sh -research "prompt" [N] # Keep/discard autonomous loop
codex-loop.sh -hook-update           # Refresh codebase status
codex-loop.sh -status                # Show active session
codex-loop.sh -cancel                # Cancel active session
codex-loop.sh -cleanup               # Delete stale branches
```

## Opus 探索/规划原则

Opus 在 Phase 0-1 中必须遵守：

**实事求是 + 第一性原理**:
- 只报告已确认的事实。未读代码先声明再验证。
- 每个决策问 "WHY?" — 最短正确路径，不是最容易的路径。
- 全链路思考: entry→processing→output→tests→callers，无盲区。

**反懒惰 (Opus 层)**:
- 不做表面分解 → 读源码理解真正的依赖关系再分 story
- 不猜测 scope → grep/cat 验证每个 story 的文件是否真正 disjoint
- 不重复同一方向 → 失败后必须探索完全不同的方案

**失败升级 (Opus 层)**:
- L1: -ralph 返回失败 → 读 `_feedback.md`，修正 plan 重来
- L2: 连续 2 次失败 → 探索完全不同的架构方案
- L3: 连续 3 次失败 → 重新读所有相关源码，从第一性原理重新分解

**冰山方法论 (成功后)**:
- Q1: 这个 fix 的相邻模块有类似问题吗？
- Q2: 能否从这次修复中提取通用模式？
- Q3: 下一批 story 应该探索什么方向？

## L3 TASK Format (Opus writes this)

```markdown
## Story {id}: {title}
scope: [file1.rs, file2.rs]
depends: [1, 2] | none
verification: cargo check -p {crate} && cargo test -p {crate}

### Context
{Read via Bash("cat ...") — signatures, current impl, call chains}

### Requirement
{Precise, no ambiguity}

### Plan
1. {specific change}
2. {step 2}

### Constraints
- Stay on main. No branches. Only modify files in scope.
- 实事求是: report exact facts, never fabricate.
- 第一性原理: WHY before HOW. Shortest correct path.
- 全链路: trace entry→processing→output→tests→callers.
- 闭环验证: cargo check/test output as evidence.
- Offensive programming: is_finite(), saturating_*, OHLCV constraints.
```

## Story Rules

1. Read source via Bash before writing  2. Bottom-up DAG order  3. Disjoint scope per round  4. Independently verifiable  5. One change per story

## Failure Escalation

| Level | Trigger | Action |
|-------|---------|--------|
| L0 | Normal | Execute directly |
| L1 | 1 fail | Re-read error, correct approach |
| L2 | 2 fails | Fundamentally different approach. Grep codebase. |
| L3 | 3 fails | 7-point checklist (see below). Try OPPOSITE assumption. |
| L4 | 4+ fails | STOP. Read every relevant file. Map full call chain. |

**L3 Checklist**: 1.Read exact error 2.Grep related code 3.Read 50 lines context 4.Verify all assumptions 5.Try opposite 6.Minimal repro 7.Switch angle completely

## Anti-Laziness (5 forbidden patterns)

1. **暴力重试** → analyze WHY, don't retry same thing
2. **甩锅** → you have Bash, verify yourself
3. **闲置工具** → use grep/cat/Bash, never say "I can't see"
4. **忙而无功** → generate new evidence before tweaking
5. **被动等待** → verify, extend, check edge cases after fix

## Research Mode

`Bash("codex-loop.sh -research 'direction' [N]")` — autonomous keep/discard loop.
TSV log at `state/research-log.tsv`. Baseline commit tracking. 3 consecutive discards → stop.

## Codex Output Format

```
=== CODEX SUMMARY ===
status: complete | partial | blocked
task: <one-line description>
files_changed: <comma-separated>
tests_run: <commands executed>
tests_passed: true | false
remaining: none | <specific remaining items>
error: none | <error description>
=== END CODEX SUMMARY ===
```

## Appendix

```yaml
workspace: auto-detect (git rev-parse --show-toplevel)
codex_flags: --dangerously-bypass-approvals-and-sandbox
task_timeout: 600000
```

- **Scan**: `codex-loop.sh -scan` → `state/scan-results.md`
- **Hook**: `PostToolUse` → `codex-loop.sh -hook-update` → `state/codebase-status.md`
- **System prompt**: `codex-system-prompt.md` (L1 — thinking, anti-laziness, escalation, red lines)
