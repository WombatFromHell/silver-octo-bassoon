# General Rules
- Always plan and explicitly request approval before committing to changing existing files unless the user explicitly states otherwise.
- If the user requests a 'quick code review' or 'quick code plan' we skip the `Always use FINDINGS.md->PLAN.md->REVIEW.md` workflow rule and our `Delegate to subagents` rule, prompting the user with our action plan composed of granular vertical slices.
- When possible use TDD (test driven development) leveraging ponytail rules when planning changes.
- Always use a 'FINDINGS.md' -> 'PLAN.md' -> 'REVIEW.md' workflow, unless the 'quick code review' or 'quick code plan' rule is called, where progress is kept up to date on task boundries, and keep these files under the '.pi/' directory of a project.
- Delegate to our subagents (see subagent rules below) when we need to explore, plan, or review code. Code changes must always be done in our main session.

# Tool Usage Rules
- Always try context-mode commands first before falling back to built-ins, e.g.: 'ctx_batch_execute', 'ctx_execute', 'ctx_execute_file', 'ctx_index', 'ctx_search', 'ctx_fetch_and_index'
- Only use bash commands that are gated with a timeout (max 5 minutes), and prompt explicitly if more time is required.

# Subagent Usage Rules

- **One at a time.** Spawn a single subagent, wait for its result, then decide on the next. Never launch parallel children.
- **Foreground only.** Spawn with `async: false` so the run blocks until done. Never background subagent work.
- **User-defined agents only.** Use `explorer`, `planner`, or `reviewer`. Do not use builtin agents (worker, scout, oracle, delegate, researcher, etc.) or external-CLI agents.

# Ponytail Rules

- **Code reviews.** When asked for a code review, always delegate to `reviewer` for a systematic, thorough, and adversarial review applying ponytail rules: YAGNI / KISS / DRY / SoC / composability / maintainability, unless the user requests a 'quick code review' or 'quick code plan'.
- **Quick code reviews.** When asked for a 'quick code review' or 'quick code plan' we still apply a systematic, thorough, and adversarial review methodology that aggressively applies the ponytail rules: YAGNI / KISS / DRY / SoC / composability / maintainability but we do *not* call a subagent - everything must be done in the current work session and logged to a 'PLAN.md' under the '.pi/' subfolder and frequently updated at task boundries.
- **All other code changes/additions.** Apply the same ponytail rules (YAGNI / KISS / DRY / SoC / composability / maintainability) in all circumstances where code is being changed or added, unless explicitly requested otherwise.
