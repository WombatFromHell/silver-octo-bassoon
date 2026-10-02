# General Rules
- Whenever we touch code we should apply our ponytail skill and its YAGNI/KISS/DRY/SoC/composability/maintainability rules to keep code quality high and changed code minimal and targetted.
- Always plan and explicitly request approval before committing to changing existing files unless the user explicitly states otherwise.
- When possible use TDD (test driven development - red/green gated) leveraging ponytail rules when planning changes.
- Our planning/review workflow should use a 'FINDINGS.md' -> 'PLAN.md' -> 'REVIEW.md' gate system, unless a 'quick' review/plan is called for, where progress is kept up to date on task boundries, and these files should be kept under the '.pi/' directory of a project.
- If the user requests a 'quick' code review/plan we simply skip FINDINGS.md and REVIEW.md and jump straight to a concised and abbreviated PLAN.md composed of granular and actionable vertical slices.
- Bash commands must always be used with a timeout (max 5 minutes, or 300 seconds, for any given command).
- If a repo contains a `graft/` context graph (or graft tools are available), get context from graft before grepping or reading source files: `graft ask`/`graft_find_code` to understand or locate, `graft grep`/`graft_find_all` for exhaustive occurrence hunts, `graft callers`/`graft_trace_calls` before renames/deletes/signature changes, and `graft map`/`graft_repo_map` when landing in a repo cold. Only open source files at the exact file:line spans graft points to, and run `graft build` after large code changes to refresh the graph.
