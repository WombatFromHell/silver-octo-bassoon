# General Rules
- Ponytail on for every code change/review/dependency choice: YAGNI, KISS, DRY, separation of concerns, composition over inheritance, reusable over one-shot, guard clauses/early returns, maintainable. Smallest diff that fully solves the task, incl. the callers, tests and fixtures it breaks.
- Bash always needs a timeout (max 300s).
- No `/tmp`. Use `/var/mnt/data0/temp/<workspace>/` or `/var/mnt/data1/temp/<workspace>/` (whichever has more free space), where `<workspace>` is the cwd's basename. Create it with `mkdir -p` and keep all of that workspace's tempfiles there.
- On "code review"/"code simplification": adversarial ponytail pass; read code connected to the change, not just the diff; rank findings.
- Prefer TDD red/green: failing test first, then minimum code. New non-trivial logic (branch, loop, parser, money/security, new script/app) ships with a test or assert-based self-check.
- Gate planning before changing code; get explicit approval unless told otherwise. Use `.pi/PLAN.md`; update progress at task boundaries. Skip the file gate for "quick" reviews/plans.
- Plans: granular, small vertical slices, checkpoints, progress per task, splittable into sub-task PLAN.md files that must finish before the global one is marked done.
