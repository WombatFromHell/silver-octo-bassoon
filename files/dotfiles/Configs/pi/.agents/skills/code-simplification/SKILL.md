---
name: code-simplification
description: Simplifies code for clarity. Use when refactoring code for clarity without changing behavior. Use when code works but is harder to read, maintain, or extend than it should be. Use when reviewing code that has accumulated unnecessary complexity.
---

# Code Simplification

Reduce complexity while preserving behavior exactly. The goal is comprehension speed, not fewer lines: a change is worth making only if a new team member understands it faster.

**Contents:** [When to Use](#when-to-use) · [Core Rules](#core-rules) · [Procedure](#procedure) · [Patterns](#patterns) · [Pitfalls](#pitfalls) · [Verification](#verification) · [Sources](#sources)

## When to Use

- Feature works and tests pass, but the implementation is heavier than it needs to be.
- A review flagged readability or complexity.
- Deep nesting, long functions, or unclear names.
- Code written under time pressure; related logic scattered across files; a merge added duplication.

**Skip when:** code is already clean; you don't yet understand what it does; it's performance-critical and the "simpler" version is measurably slower; the module is about to be rewritten anyway.

## Core Rules

1. **Preserve behavior exactly.** Same output for every input, same errors, same side effects and ordering, same edge cases. If you can't prove that, don't make the change.
2. **Follow project conventions.** Read `CLAUDE.md`/`AGENTS.md` and how neighbouring code handles the same pattern; match import order, declaration style, naming, error handling, and type depth. Simplification that breaks consistency is churn.
3. **Prefer clarity over cleverness.** Explicit beats compact when the compact version needs a mental pause:

   ```ts
   // unclear: ternary chain
   const label = isNew ? 'New' : isUpdated ? 'Updated' : 'Archived';
   // clear: guard chain in a named function
   function getStatusLabel(item: Item): string {
     if (item.isNew) return 'New';
     if (item.isUpdated) return 'Updated';
     return 'Active';
   }
   ```
4. **Don't over-simplify.** Over-simplification traps: inlining away a helper that gave a concept a name; merging two simple functions into one complex one; deleting an abstraction that exists for extensibility or testability; optimizing for line count.
5. **Scope to what changed.** Default to recently modified code. Unscoped drive-by refactors produce noisy diffs and risk regressions in code you didn't intend to touch.

## Procedure

1. **Understand before touching** — Chesterton's Fence. Before changing or removing anything, answer: what is this code's responsibility; what calls it and what does it call; what are the edge cases and error paths; do tests pin the expected behavior; why was it written this way (performance, platform, history)? Check `git blame` for the original context. If you can't answer these, read more context first.
2. **Scan for concrete signals** — see [Patterns](#patterns).
3. **Apply one simplification at a time.** Change → run the test suite → pass: continue or commit; fail: revert and reconsider. Don't batch several into one untested change — you need to know which one broke. Submit refactors separately from features and fixes (a PR that refactors and adds a feature is two PRs). **Rule of 500:** past 500 lines, automate (codemods, sed, AST transforms) rather than hand-edit.
4. **Compare before and after.** Genuinely easier? No patterns foreign to the codebase? Diff reviewable? If the "simplified" version reads worse or a teammate wouldn't approve it, revert.

## Patterns

| Pattern | Signal | Simplification |
|---|---|---|
| Deep nesting (3+ levels) | hard-to-follow control flow | guard clauses or extracted helpers |
| Long function (50+ lines) | multiple responsibilities | split into focused, well-named functions |
| Nested ternaries | needs a mental stack | if/else chain, `switch`, or lookup object |
| Boolean flag params | `doThing(true, false, true)` | options object or separate functions |
| Repeated conditionals | same `if` in several places | extract a well-named predicate |
| Generic names | `data`, `result`, `temp`, `val` | name the content: `userProfile`, `validationErrors` |
| Abbreviated names | `usr`, `cfg`, `btn`, `evt` | full words unless universal (`id`, `url`, `api`) |
| Misleading names | `get` that also mutates state | rename to the actual behavior |
| Comments explaining *what* | `// increment counter` over `count++` | delete — the code already says it |
| Comments explaining *why* | `// Retry because the API is flaky` | keep — intent the code can't express |
| Duplicated logic | same 5+ lines repeated | extract a shared function |
| Dead code | unreachable branches, unused vars, commented-out blocks | remove after confirming it's truly dead |
| Useless wrapper | adds no value | call the underlying function directly |
| Over-engineered pattern | factory-for-a-factory, strategy-with-one-strategy | the simple direct approach |
| Redundant type assertion | cast to an already-inferred type | remove it |

### Mechanical rewrites

```ts
// drop a pass-through async wrapper
function getUser(id: string): Promise<User> { return userService.findById(id); }
// conditional assignment
const displayName = user.nickname || user.fullName;
// filter instead of build-a-list loop
const activeUsers = users.filter((user) => user.isActive);
```

```python
# dict comprehension
result = {item.id: item.name for item in items}

# early returns instead of nested conditionals
def process(data):
    if data is None:
        raise TypeError("Data is None")
    if not data.is_valid():
        raise ValueError("Invalid data")
    if not data.has_permission():
        raise PermissionError("No permission")
    return do_work(data)
```

```tsx
// conditional rendering: pick props, render once
const variant = user.isAdmin ? 'admin' : 'default';
return <Badge variant={variant}>{user.isAdmin ? 'Admin' : 'User'}</Badge>;
```

Prop drilling is a judgment call (context vs composition) — flag it, don't auto-refactor.

## Pitfalls

- Tests had to be modified to pass → you changed behavior.
- "Simplified" code that is longer or harder to follow than the original.
- Renaming to your preferences instead of project conventions.
- Removing or weakening error handling "to make it cleaner".
- Simplifying code you don't fully understand, batching several into one hard-to-review commit, or touching code outside the task scope.

| Rationalization | Reality |
|---|---|
| "It's working, don't touch it" | Hard to read = hard to fix when it breaks. |
| "Fewer lines is simpler" | A 1-line ternary isn't simpler than 5 lines of if/else. |
| "The types make it self-documenting" | Types document structure, not intent. |
| "This abstraction might be useful later" | Speculative complexity — remove it, re-add when needed. |
| "The original author must have had a reason" | Check `git blame`; accumulated complexity is usually residue of iteration under pressure. |

## Verification

- [ ] All existing tests pass **without modification**.
- [ ] Build succeeds with no new warnings; linter/formatter clean (no style regressions).
- [ ] Each simplification is a separate, reviewable commit; the diff has no unrelated changes.
- [ ] Code matches project conventions (checked against `CLAUDE.md`/`AGENTS.md`).
- [ ] No error handling removed or weakened; no dead code left (unused imports, unreachable branches).
- [ ] A reviewer would call the change a net improvement.

## Sources

- Adapted from the [Claude Code Simplifier plugin](https://github.com/anthropics/claude-plugins-official/blob/main/plugins/code-simplifier/agents/code-simplifier.md), as a model-agnostic process.
