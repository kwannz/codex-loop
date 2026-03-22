#!/usr/bin/env bash
set -euo pipefail

# ─── Codex Loop — Opus↔Codex collaboration tool ──────────────────────────────
#
# Modes:
#   default / -ralph    : ralph parallel (multi-story via prd.json, all on main)
#   -scan              : full codebase scan
#   -research          : autonomous keep/discard research loop

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

# Workspace: use git root if available, else PROJECT_ROOT, else PWD
WORKSPACE="$(git rev-parse --show-toplevel 2>/dev/null || echo "${PROJECT_ROOT:-$PWD}")"
CODEX_FLAGS="--dangerously-bypass-approvals-and-sandbox"

STATE_DIR="$SKILL_DIR/state"
STATE_FILE="$STATE_DIR/codebase-status.md"
SCAN_FILE="$STATE_DIR/scan-results.md"
SYSTEM_PROMPT_FILE="$SKILL_DIR/codex-system-prompt.md"
HOOK_LOCK="$STATE_DIR/.hook-lock"
LOOP_STATE="$STATE_DIR/.codex-loop.state"
RESEARCH_LOG="$STATE_DIR/research-log.tsv"
ITER_SLEEP=2
LOOP_STARTED_AT=""

ensure_state_dir() { mkdir -p "$STATE_DIR"; }

# ─── Cached detection (once per session) ──────────────────────────────────────
BUILD_CMD=""
TEST_CMD=""
cache_build_test_cmds() {
  [[ -n "$BUILD_CMD" ]] && return
  if [[ -f "$WORKSPACE/Cargo.toml" ]]; then BUILD_CMD="cargo check --workspace"; TEST_CMD="cargo test --workspace"
  elif [[ -f "$WORKSPACE/package.json" ]]; then BUILD_CMD="npm run build"; TEST_CMD="npm test"
  elif [[ -f "$WORKSPACE/go.mod" ]]; then BUILD_CMD="go build ./..."; TEST_CMD="go test ./..."
  else BUILD_CMD="echo 'no build cmd'"; TEST_CMD="echo 'no test cmd'"
  fi
}

# ─── Cached system prompt (once per session) ──────────────────────────────────
_SYS_PROMPT_CACHE=""
get_system_prompt() {
  if [[ -z "$_SYS_PROMPT_CACHE" && -f "$SYSTEM_PROMPT_FILE" ]]; then
    _SYS_PROMPT_CACHE=$(cat "$SYSTEM_PROMPT_FILE" 2>/dev/null || true)
  fi
  echo "$_SYS_PROMPT_CACHE"
}

# ─── Shared verify helper ────────────────────────────────────────────────────
# Returns: sets VERIFY_BUILD_RC, VERIFY_TEST_RC, VERIFY_BUILD_OUT, VERIFY_TEST_OUT
run_verify() {
  local run_test="${1:-1}"  # 0 = skip test
  cache_build_test_cmds
  VERIFY_BUILD_RC=1; VERIFY_TEST_RC=1; VERIFY_BUILD_OUT=""; VERIFY_TEST_OUT=""
  if VERIFY_BUILD_OUT=$(cd "$WORKSPACE" && eval "$BUILD_CMD" 2>&1); then
    VERIFY_BUILD_RC=0
    if [[ "$run_test" == "1" ]]; then
      if VERIFY_TEST_OUT=$(cd "$WORKSPACE" && eval "$TEST_CMD" 2>&1); then
        VERIFY_TEST_RC=0
      fi
    fi
  fi
}

# ─── Shared parse helpers ────────────────────────────────────────────────────

extract_summary_block() {
  sed -n '/=== CODEX SUMMARY ===/,/=== END CODEX SUMMARY ===/p' "$1" 2>/dev/null || true
}

# Safe parsing — no eval, no injection from LLM output
parse_summary() {
  local blk; blk=$(extract_summary_block "$1")
  [[ -z "$blk" ]] && { echo "NO_SUMMARY"; return; }
  echo "$blk" | awk -F: '
    {key=tolower($1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
     val=$0; sub(/^[^:]*:/, "", val); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val); val=tolower(val)}
    key=="status"       {st=val}
    key=="tests_passed" {tp=val}
    key=="remaining"    {rem=val}
    END {
      if (st=="complete" && tp=="true" && rem=="none") print "COMPLETE"
      else if (st=="blocked") print "BLOCKED"
      else if (st=="complete" && tp!="true") print "TESTS_FAILED"
      else if (st=="partial" || (rem!="none" && rem!="" && rem!="unknown")) print "PARTIAL"
      else print "UNKNOWN"
    }'
}

# Handles colons in task description (e.g., "task: fix error: missing field")
parse_task_desc() {
  local blk; blk=$(extract_summary_block "$1")
  local d; d=$(echo "$blk" | awk 'tolower($0) ~ /^task:/ {sub(/^[^:]*:/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit}')
  echo "${d:-unknown}"
}

write_loop_state() {
  local mode="$1" iter="$2" max="$3" phase="${4:-running}" last_output="${5:-}" note="${6:-}"
  [[ -n "$LOOP_STARTED_AT" ]] || LOOP_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$LOOP_STATE" <<EOF
active: true
mode: $mode
iteration: $iter
max: $max
phase: $phase
workspace: $WORKSPACE
started: $LOOP_STARTED_AT
updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
pid: $$
last_output: ${last_output:-none}
note: ${note:-none}
EOF
}

cleanup_loop_state() { rm -f "$LOOP_STATE"; }

workspace_has_changes() {
  [[ -n "$(git -C "$WORKSPACE" status --short 2>/dev/null || true)" ]]
}

# ─── Ralph progress helpers ──────────────────────────────────────────────────

init_ralph_progress() {
  local pf; pf="$(dirname "$1")/progress.txt"
  [[ -f "$pf" ]] || { echo "# Ralph Progress — $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$pf"; echo "Initialized: $pf"; }
}

append_research_log() {
  local iter="$1" commit="$2" status="$3" build="$4" test="$5" description="$6" files="$7"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$iter" "$commit" "$status" "$build" "$test" "$description" "${files:-none}" >> "$RESEARCH_LOG"
}

ensure_research_log() {
  local baseline="$1"
  if [[ ! -f "$RESEARCH_LOG" ]]; then
    printf 'iter\tcommit\tstatus\tbuild\ttest\tdescription\tfiles\n' > "$RESEARCH_LOG"
  fi
  if [[ "$(wc -l < "$RESEARCH_LOG" | tr -d ' ')" == "1" ]]; then
    append_research_log "0" "${baseline:0:7}" "keep" "pass" "pass" "baseline" "none"
  fi
}

# ─── Mandatory output format / safety ─────────────────────────────────────────
MANDATORY_OUTPUT_FORMAT='

=== MANDATORY OUTPUT FORMAT ===
You MUST end your response with this structured block.

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
=== END MANDATORY OUTPUT FORMAT ==='


# ─── hook-update ──────────────────────────────────────────────────────────────

do_hook_update() {
  if [[ -f "$HOOK_LOCK" ]]; then
    local lock_ts=0
    lock_ts=$(stat -f %m "$HOOK_LOCK" 2>/dev/null || stat -c %Y "$HOOK_LOCK" 2>/dev/null || echo 0)
    (( $(date +%s) - lock_ts < 30 )) && return 0
  fi
  ensure_state_dir; touch "$HOOK_LOCK"; trap 'rm -f "$HOOK_LOCK"' RETURN
  {
    echo "# Codebase Status (live)"
    echo "Updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "## Git"
    echo "Branch: $(git -C "$WORKSPACE" branch --show-current 2>/dev/null || echo unknown)"
    echo '```'
    git -C "$WORKSPACE" log --oneline -3 2>/dev/null || true
    echo '```'
    echo "## Uncommitted"
    echo '```'
    git -C "$WORKSPACE" status --short 2>/dev/null | head -20 || true
    echo '```'
  } > "$STATE_FILE" 2>/dev/null || true
}

# ─── scan ─────────────────────────────────────────────────────────────────────

do_scan() {
  ensure_state_dir; cache_build_test_cmds
  echo "Scanning workspace: $WORKSPACE ..." >&2
  {
    echo "# Codebase Scan"
    echo "Updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "## Git State"
    echo "Branch: $(git -C "$WORKSPACE" branch --show-current 2>/dev/null || echo unknown)"
    echo '```'
    git -C "$WORKSPACE" log --oneline -5 2>/dev/null || true
    echo '```'
    echo "### Uncommitted"
    echo '```'
    git -C "$WORKSPACE" status --short 2>/dev/null | head -30 || true
    echo '```'
    echo "## Build Status"
    echo '```'
    (cd "$WORKSPACE" && eval "$BUILD_CMD" 2>&1 | tail -15 || true)
    echo '```'
    echo "## Test Count"
    echo '```'
    if [[ -f "$WORKSPACE/Cargo.toml" ]]; then
      { grep -rc '#\[test\]' "$WORKSPACE/crates/" "$WORKSPACE/apps/" "$WORKSPACE/src/" --include='*.rs' 2>/dev/null || true; } \
        | awk -F: '{s+=$2}END{printf "Total #[test]: %d\n", s}'
    fi
    echo '```'
    echo "## Issues"
    echo '```'
    grep -rn -m 5 'TODO\|FIXME\|HACK' "$WORKSPACE" --include='*.rs' --include='*.ts' --include='*.go' --include='*.py' \
      --exclude-dir=node_modules --exclude-dir=target --exclude-dir=.git 2>/dev/null | head -20 || echo "None"
    echo '```'
  } > "$SCAN_FILE"
  do_hook_update
  echo "Scan complete: $SCAN_FILE" >&2
}

# ─── build_prompt ─────────────────────────────────────────────────────────────

build_prompt() {
  local prompt_arg="$1" prompt_file="$2" lightweight="${3:-0}"
  local sys; sys=$(get_system_prompt)

  if [[ -n "$sys" ]]; then
    echo "=== CODEX SYSTEM PROMPT ==="
    echo "$sys"
    echo "=== END CODEX SYSTEM PROMPT ==="
    echo ""
  fi

  if [[ "$lightweight" != "1" ]]; then
    echo "=== CODEBASE STATUS ==="
    if [[ -f "$SCAN_FILE" ]]; then cat "$SCAN_FILE"
    elif [[ -f "$STATE_FILE" ]]; then cat "$STATE_FILE"
    else echo "No status available."
    fi
    echo "=== END CODEBASE STATUS ==="
    echo ""
  fi

  echo "=== TASK ==="
  local has=0
  [[ -n "$prompt_file" && -f "$prompt_file" ]] && { cat "$prompt_file"; has=1; }
  [[ -n "$prompt_arg" ]] && { [[ "$has" -eq 1 ]] && echo ""; echo "$prompt_arg"; has=1; }
  [[ "$has" -eq 0 ]] && { echo "ERROR: No prompt provided."; return 1; }
  echo ""
  echo "=== END TASK ==="
  echo "$MANDATORY_OUTPUT_FORMAT"
}

# ─── do_dispatch (single Codex invocation) ────────────────────────────────────

do_dispatch() {
  local prompt_arg="$1" prompt_file="$2" output_file="$3" model="$4" read_only="${5:-0}" lightweight="${6:-0}" prompt_dump_file="${7:-}"

  command -v codex >/dev/null 2>&1 || { echo "Error: codex not in PATH" >&2; return 1; }
  [[ -z "$prompt_arg" && -z "$prompt_file" ]] && { echo "Error: no prompt" >&2; return 1; }
  [[ ! -f "$STATE_FILE" && ! -f "$SCAN_FILE" ]] && do_hook_update

  ensure_state_dir
  [[ -z "$output_file" ]] && { mkdir -p /tmp/codex-loop; output_file="/tmp/codex-loop/$(date +%Y%m%dT%H%M%S)-$$.md"; }

  local -a args=(exec -C "$WORKSPACE" -o "$output_file")
  [[ "$read_only" == "1" ]] && args+=(--sandbox read-only) || args+=("$CODEX_FLAGS")
  [[ -n "$model" ]] && args+=(--model "$model")

  local tmp; tmp=$(mktemp -t codex-prompt.XXXXXX)
  trap "rm -f '$tmp'" RETURN
  build_prompt "$prompt_arg" "$prompt_file" "$lightweight" > "$tmp" 2>/dev/null || return 1
  [[ -n "$prompt_dump_file" ]] && cp "$tmp" "$prompt_dump_file"

  local ec=0
  codex "${args[@]}" < "$tmp" || ec=$?

  echo "Codex exit=$ec output=$output_file summary=$(parse_summary "$output_file" 2>/dev/null || echo NONE)"
  return "$ec"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ─── -research: keep/discard loop (NEVER STOP. NEVER ASK.) ───────────────────
# ═══════════════════════════════════════════════════════════════════════════════

do_research() {
  local prompt_arg="$1" prompt_file="$2" model="$3" max_iter="$4"
  [[ "$max_iter" =~ ^[1-9][0-9]*$ ]] || { echo "Error: max_iter must be positive int" >&2; exit 1; }
  [[ -z "$prompt_arg" && -z "$prompt_file" ]] && { echo "Error: -research requires a prompt" >&2; exit 1; }

  ensure_state_dir; mkdir -p "$STATE_DIR/outputs"; cache_build_test_cmds
  local baseline; baseline=$(git -C "$WORKSPACE" rev-parse HEAD 2>/dev/null || echo unknown)
  ensure_research_log "$baseline"
  write_loop_state "research" 1 "$max_iter"
  trap 'cleanup_loop_state' EXIT

  echo "RESEARCH: max=$max_iter baseline=${baseline:0:8} NEVER STOP. NEVER ASK."

  local iter=1 stall=0
  while [[ "$iter" -le "$max_iter" ]]; do
    [[ ! -f "$LOOP_STATE" ]] && { echo "RESEARCH: CANCELLED"; return 0; }
    echo "--- research $iter / $max_iter ---"

    local out="$STATE_DIR/outputs/research-iter-${iter}.md"
    local prompt_snapshot="$STATE_DIR/outputs/research-iter-${iter}.prompt.md"
    write_loop_state "research" "$iter" "$max_iter" "dispatching" "$out" "baseline=${baseline:0:8}"
    local prompt="$prompt_arg"
    if [[ "$iter" -gt 1 && -f "$RESEARCH_LOG" ]]; then
      local log_body; log_body=$(tail -n +2 "$RESEARCH_LOG" | tail -20)
      prompt="=== RESEARCH $iter/$max_iter ===
=== LOG ===
$(head -1 "$RESEARCH_LOG")
$log_body
=== END LOG ===
Do NOT repeat discarded approaches. Try new direction.
Direction: $prompt_arg"
    fi

    local lw=0; [[ "$iter" -gt 1 ]] && lw=1
    local ec=0; do_dispatch "$prompt" "$prompt_file" "$out" "$model" "0" "$lw" "$prompt_snapshot" || ec=$?

    if [[ ! -s "$out" ]]; then
      local reason="empty_output"
      [[ "$ec" -ne 0 ]] && reason="dispatch_exit_${ec}"
      write_loop_state "research" "$iter" "$max_iter" "stalled" "$out" "$reason"
      stall=$((stall+1)); append_research_log "$iter" "" "stall" "-" "-" "$reason" ""
      [[ "$stall" -ge 3 ]] && { echo "RESEARCH: 3 stalls, stopping"; return 4; }
      iter=$((iter+1)); continue
    fi
    stall=0

    local desc; desc=$(parse_task_desc "$out")
    local verdict; verdict=$(parse_summary "$out")
    run_verify 1
    local files; files=$(git -C "$WORKSPACE" diff --name-only 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    [[ -z "$files" ]] && files="none"

    if [[ "$VERIFY_BUILD_RC" -eq 0 && "$VERIFY_TEST_RC" -eq 0 ]]; then
      if workspace_has_changes; then
        (cd "$WORKSPACE" && git add -A && git commit -m "research #${iter}: ${desc}") >/dev/null 2>&1 || true
        baseline=$(git -C "$WORKSPACE" rev-parse HEAD)
      fi
      append_research_log "$iter" "${baseline:0:7}" "keep" "pass" "pass" "$desc [$verdict]" "$files"
      write_loop_state "research" "$iter" "$max_iter" "kept" "$out" "commit=${baseline:0:8}"
      echo "  KEEP ${baseline:0:8}"
    else
      local err=""
      [[ "$VERIFY_BUILD_RC" -ne 0 ]] && err=$(echo "$VERIFY_BUILD_OUT" | grep -E 'error' | head -3 | tr '\n' '; ')
      [[ "$VERIFY_TEST_RC" -ne 0 ]] && err=$(echo "$VERIFY_TEST_OUT" | grep -E 'FAILED|error' | head -3 | tr '\n' '; ')
      if ! git -C "$WORKSPACE" reset --hard "$baseline" 2>&1; then
        echo "RESEARCH: FATAL — reset to $baseline failed" >&2
        append_research_log "$iter" "" "reset_failed" "fail" "fail" "reset --hard failed" "none"
        break
      fi
      local st="discard"; [[ "$VERIFY_BUILD_RC" -ne 0 ]] && st="crash"
      local bv="fail" tv="fail"
      [[ "$VERIFY_BUILD_RC" -eq 0 ]] && bv="pass"
      [[ "$VERIFY_TEST_RC" -eq 0 ]] && tv="pass"
      append_research_log "$iter" "" "$st" "$bv" "$tv" "$desc [$verdict] (${err:-verify_failed})" "$files"
      write_loop_state "research" "$iter" "$max_iter" "$st" "$out" "${err:-verify_failed}"
      echo "  ${st^^} → reset ${baseline:0:8}"
    fi
    iter=$((iter+1)); sleep "$ITER_SLEEP"
  done
  echo "RESEARCH: done. Log: $RESEARCH_LOG"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ─── cleanup ─────────────────────────────────────────────────────────────────
# ═══════════════════════════════════════════════════════════════════════════════

cleanup_stale_branches() {
  git -C "$WORKSPACE" worktree prune 2>/dev/null || true
  local to_delete=()
  while read -r b; do
    [[ -n "$b" ]] && to_delete+=("$b")
  done < <(git -C "$WORKSPACE" branch --list "worktree-agent-*" "codex-parallel/*" 2>/dev/null \
    | sed 's/^[* +]*//')
  if [[ ${#to_delete[@]} -gt 0 ]]; then
    git -C "$WORKSPACE" branch -D "${to_delete[@]}" 2>/dev/null || true
    echo "CLEANUP: removed ${#to_delete[@]} stale branch(es): ${to_delete[*]}"
  else
    echo "CLEANUP: no stale branches"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# ─── ralph-parallel: multi-story parallel dispatch on main (DEFAULT) ──────────
# ═══════════════════════════════════════════════════════════════════════════════

# Extract write_root from story prompt's scope: line
# scope: [file1.rs, dir/file2.rs] → common parent directory
extract_write_root() {
  local prompt_file="$1"
  local scope_line; scope_line=$(grep -m1 '^scope:' "$prompt_file" 2>/dev/null || true)
  [[ -z "$scope_line" ]] && return
  # Parse [file1, file2] → find common parent dir
  local raw; raw=$(echo "$scope_line" | sed 's/^scope:[[:space:]]*\[//;s/\].*//;s/,/ /g;s/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s ' ')
  [[ -z "$raw" ]] && return
  local common=""
  for f in $raw; do
    local d; d=$(dirname "$f")
    if [[ -z "$common" ]]; then
      common="$d"
    else
      while [[ "$d/" != "$common/"* && "$common" != "." ]]; do
        common=$(dirname "$common")
      done
    fi
  done
  [[ -n "$common" && "$common" != "." ]] && echo "$common"
}

collect_prompts() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    find "$dir" -maxdepth 1 -name '*.md' -not -name '_*' -not -name '*-output.md' -type f | sort
  elif [[ -f "$dir" ]]; then
    echo "$dir"
  fi
}

build_ralph_context() {
  local prd_file="$1"
  cat "$prd_file"
  local dir; dir="$(dirname "$prd_file")"
  [[ -f "$dir/progress.txt" ]] && { echo ""; tail -80 "$dir/progress.txt"; }
  # Inject previous round's feedback if exists
  local fb="$STATE_DIR/outputs/_feedback.md"
  [[ -f "$fb" ]] && { echo ""; echo "=== PREVIOUS ROUND FEEDBACK ==="; cat "$fb"; echo "=== END FEEDBACK ==="; }
}

# Single round: dispatch all prompts in parallel, wait, verify
ralph_dispatch_round() {
  local prompt_dir="$1" model="$2" prd_file="$3" round="$4"

  local prompts=()
  while IFS= read -r f; do prompts+=("$f"); done < <(collect_prompts "$prompt_dir")
  [[ ${#prompts[@]} -lt 1 ]] && { echo "Error: no prompt files in $prompt_dir" >&2; return 1; }

  local ctx; ctx=$(build_ralph_context "$prd_file")
  local total=${#prompts[@]}

  echo "RALPH round=$round: $total stories on main"

  local pids=() tmpfiles=()
  ROUND_OUTPUTS=(); ROUND_AIDS=()
  local idx=0
  for pf in "${prompts[@]}"; do
    idx=$((idx+1))
    local aid; aid=$(basename "$pf" .md)
    local of="$STATE_DIR/outputs/round-${round}-${aid}-output.md"

    local combined="=== PRD + PROGRESS ===
$ctx
=== END PRD + PROGRESS ===

=== RALPH TASK (round $round, agent $idx/$total) ===
YOU ARE AN EXECUTOR. Opus has planned. You implement exactly as specified.

DISCIPLINE:
- 实事求是: report exact facts. Never fabricate progress.
- Execute the plan below precisely. Do not redesign or explore alternatives.
- If blocked on a specific step, report status: blocked with exact reason.
- 闭环验证: run verification command, report exact output.

RULES:
- Work on main. No branches. Only modify files in scope.
- Do NOT touch prd.json or files outside scope.
- Do NOT explore, refactor, or improve beyond the plan.

$(cat "$pf")
=== END RALPH TASK ==="

    local tmp; tmp=$(mktemp -t "ralph-r${round}-${aid}.XXXXXX")
    build_prompt "$combined" "" "0" > "$tmp" 2>/dev/null || { rm -f "$tmp"; continue; }

    local -a ca=(exec -C "$WORKSPACE" -o "$of" "$CODEX_FLAGS")
    [[ -n "$model" ]] && ca+=(--model "$model")
    # Scope isolation: restrict writes to story's directory
    local wr; wr=$(extract_write_root "$pf")
    [[ -n "$wr" ]] && ca+=(-c "write_root=$wr")

    echo "  agent-$aid: launching ($idx/$total)${wr:+ [write_root=$wr]}..."
    codex "${ca[@]}" < "$tmp" &
    pids+=($!)
    ROUND_OUTPUTS+=("$of")
    ROUND_AIDS+=("$aid")
    tmpfiles+=("$tmp")
  done

  # Wait for all
  ROUND_OK=0; ROUND_FAIL=0
  for i in "${!pids[@]}"; do
    local ec=0
    wait "${pids[$i]}" || ec=$?
    local v="UNKNOWN"; [[ -f "${ROUND_OUTPUTS[$i]}" ]] && v=$(parse_summary "${ROUND_OUTPUTS[$i]}")
    echo "  agent-${ROUND_AIDS[$i]}: exit=$ec verdict=$v"
    [[ "$ec" -eq 0 && "$v" != "BLOCKED" ]] && ROUND_OK=$((ROUND_OK+1)) || ROUND_FAIL=$((ROUND_FAIL+1))
  done

  for tf in "${tmpfiles[@]}"; do rm -f "$tf"; done
}

# Main ralph loop: Opus plans → Codex executes → verify → iterate
do_ralph() {
  local prompt_dir="$1" model="$2" prd_file="$3" max_iter="$4"

  [[ -f "$prd_file" ]] || { echo "Error: prd not found: $prd_file" >&2; return 1; }
  init_ralph_progress "$prd_file"
  ensure_state_dir; mkdir -p "$STATE_DIR/outputs"
  cache_build_test_cmds
  write_loop_state "ralph" 1 "$max_iter"
  trap 'cleanup_loop_state' EXIT

  echo "RALPH: max=$max_iter workspace=$WORKSPACE NEVER STOP. NEVER ASK."

  local iter=1 stall=0
  while [[ "$iter" -le "$max_iter" ]]; do
    [[ ! -f "$LOOP_STATE" ]] && { echo "RALPH: CANCELLED"; return 0; }
    echo "=== ralph iteration $iter / $max_iter ==="
    write_loop_state "ralph" "$iter" "$max_iter" "dispatching"

    # Dispatch all prompts in state/outputs/
    ralph_dispatch_round "$prompt_dir" "$model" "$prd_file" "$iter"

    # Verify
    run_verify 1
    local build_ok="FAIL" test_ok="FAIL"
    [[ "$VERIFY_BUILD_RC" -eq 0 ]] && build_ok="PASS"
    [[ "$VERIFY_TEST_RC" -eq 0 ]] && test_ok="PASS"
    echo "RALPH round=$iter: ok=$ROUND_OK fail=$ROUND_FAIL build=$build_ok test=$test_ok"

    if [[ "$VERIFY_BUILD_RC" -eq 0 && "$VERIFY_TEST_RC" -eq 0 && "$ROUND_FAIL" -eq 0 ]]; then
      # All passed — commit and check if done
      if workspace_has_changes; then
        (cd "$WORKSPACE" && git add -A && git commit -m "ralph round $iter: ${ROUND_OK} stories passed") >/dev/null 2>&1 || true
      fi
      write_loop_state "ralph" "$iter" "$max_iter" "passed"
      # Clean up feedback from previous failures
      rm -f "$STATE_DIR/outputs/_feedback.md"
      echo "RALPH round=$iter: PASSED — commit + done"
      return 0
    else
      # Failed — inject error feedback into prompts for next round
      write_loop_state "ralph" "$iter" "$max_iter" "failed" "" "build=$build_ok test=$test_ok"

      # Rich feedback (read by Codex agents next round)
      local diff_stat; diff_stat=$(git -C "$WORKSPACE" diff --stat 2>/dev/null | tail -5)
      local agent_summaries=""
      for i in "${!ROUND_AIDS[@]}"; do
        local sum; sum=$(extract_summary_block "${ROUND_OUTPUTS[$i]}" 2>/dev/null | head -10)
        agent_summaries+="agent-${ROUND_AIDS[$i]}: ${sum:-NO_OUTPUT}
"
      done

      cat > "$STATE_DIR/outputs/_feedback.md" <<FEEDBACK
## Round $iter Failed — L$((stall+1)) Escalation

build: $build_ok | test: $test_ok | agents_failed: $ROUND_FAIL/$((ROUND_OK+ROUND_FAIL))

### Agent Results
$agent_summaries

### Build/Test Errors
$(if [[ "$VERIFY_BUILD_RC" -ne 0 ]]; then echo "$VERIFY_BUILD_OUT" | grep -E 'error|warning' | head -30; else echo "build: PASS"; fi)
$(if [[ "$VERIFY_TEST_RC" -ne 0 ]]; then echo "$VERIFY_TEST_OUT" | grep -E 'FAILED|error|panicked' | head -30; else echo "test: PASS"; fi)

### Changed Files
$diff_stat

### Instructions for Next Round
- 第一性原理: Opus planned wrong or Codex executed wrong? Fix the ROOT CAUSE.
- Do NOT retry the same approach. Opus must rewrite prompts with corrected plan.
- L$((stall+1)): $(if [ $((stall+1)) -ge 2 ]; then echo "grep codebase for related patterns."; else echo "re-read error carefully."; fi)
$(if [ $((stall+1)) -ge 3 ]; then echo "- LAST CHANCE: try the OPPOSITE assumption. Switch angle completely."; fi)
FEEDBACK
      echo "RALPH round=$iter: FAILED — feedback written for next round"

      stall=$((stall+1))
      [[ "$stall" -ge 3 ]] && { echo "RALPH: 3 consecutive failures, stopping"; return 4; }
    fi

    iter=$((iter+1)); sleep "$ITER_SLEEP"
  done
  echo "RALPH: done after $((iter-1)) iterations"
}

# ─── usage ────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Codex Loop — Opus↔Codex multi-agent (all on main, no branches)

Usage:
  codex-loop.sh -dispatch -prompt-file F -output F  Single codex exec (Opus calls per agent)
  codex-loop.sh -ralph                              Ralph loop (script-driven iteration)
  codex-loop.sh -scan                               Codebase scan
  codex-loop.sh -research "prompt" [N]              Research keep/discard loop
  codex-loop.sh -cancel                             Cancel active session
  codex-loop.sh -cleanup                            Delete stale branches
  codex-loop.sh -status                             Show session status

Options:
  -dispatch             Single codex dispatch (Opus orchestrates multiple in parallel)
  -ralph                Ralph loop mode (script-driven, reads state/outputs/*.md)
  -ralph-prd FILE       PRD file (default: prd.json)
  -auto-max N           Max iterations (default: 10)
  -prompt-file FILE     Read prompt from file
  -model MODEL          Override Codex model
  -output FILE          Output file path
  -read-only            Read-only sandbox
  -h, -help             Show help
EOF
}

# ─── Argument parsing ────────────────────────────────────────────────────────

PROMPT_ARG="" PROMPT_FILE="" OUTPUT_FILE="" MODEL="" READ_ONLY=0
DISPATCH=0 RESEARCH=0 RALPH_PRD=""
AUTO_MAX=10 SUBCOMMAND=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -hook-update|--hook-update) SUBCOMMAND="hook-update"; shift ;;
    -scan|--scan)    SUBCOMMAND="scan"; shift ;;
    -cancel|--cancel) SUBCOMMAND="cancel"; shift ;;
    -cleanup|--cleanup) SUBCOMMAND="cleanup"; shift ;;
    -status|--status) SUBCOMMAND="status"; shift ;;
    -dispatch|--dispatch) DISPATCH=1; shift ;;
    -ralph|--ralph) shift ;;  # backward compat, default mode
    -prompt-file|--prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    -read-only|--read-only) READ_ONLY=1; shift ;;
    -research|--research) RESEARCH=1; shift ;;
    -ralph-prd|--ralph-prd) RALPH_PRD="$2"; shift 2 ;;
    -auto-max|--auto-max) AUTO_MAX="$2"; shift 2 ;;
    -model|--model)  MODEL="$2"; shift 2 ;;
    -output|--output) OUTPUT_FILE="$2"; shift 2 ;;
    -h|-help|--help) usage; exit 0 ;;
    *) [[ "$1" =~ ^[1-9][0-9]*$ && $# -eq 1 ]] && { AUTO_MAX="$1"; shift; } || { PROMPT_ARG="${PROMPT_ARG:+$PROMPT_ARG }$1"; shift; } ;;
  esac
done

case "${SUBCOMMAND:-}" in
  hook-update) do_hook_update; exit 0 ;;
  scan) do_scan; exit 0 ;;
  cancel) [[ -f "$LOOP_STATE" ]] && { rm -f "$LOOP_STATE"; echo "Cancelled"; } || echo "Nothing active"; exit 0 ;;
  cleanup) cleanup_stale_branches; exit 0 ;;
  status) [[ -f "$LOOP_STATE" ]] && cat "$LOOP_STATE" || echo "No active session"; exit 0 ;;
esac

[[ -n "$PROMPT_FILE" && ! -f "$PROMPT_FILE" ]] && { echo "Error: -prompt-file not found: $PROMPT_FILE" >&2; exit 1; }

if [[ "$DISPATCH" -eq 1 || "$READ_ONLY" -eq 1 ]]; then
  do_dispatch "$PROMPT_ARG" "$PROMPT_FILE" "$OUTPUT_FILE" "$MODEL" "$READ_ONLY"
elif [[ "$RESEARCH" -eq 1 ]]; then
  do_research "$PROMPT_ARG" "$PROMPT_FILE" "$MODEL" "$AUTO_MAX"
else
  # Default: ralph loop (plan → dispatch → verify → iterate)
  [[ -z "$RALPH_PRD" ]] && RALPH_PRD="$PROJECT_ROOT/prd.json"
  _ralph_dir="$STATE_DIR/outputs"
  mkdir -p "$_ralph_dir"
  if [[ -n "$PROMPT_ARG" || -n "$PROMPT_FILE" ]]; then
    # Single prompt → write to ralph dir as 1-story
    if [[ -n "$PROMPT_FILE" ]]; then
      cp "$PROMPT_FILE" "$_ralph_dir/story.md"
    else
      echo "$PROMPT_ARG" > "$_ralph_dir/story.md"
    fi
  fi
  do_ralph "$_ralph_dir" "$MODEL" "$RALPH_PRD" "$AUTO_MAX"
fi
