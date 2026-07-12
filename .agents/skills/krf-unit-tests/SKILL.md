---
name: krf-unit-tests
description: Writing, editing, or reviewing unit tests for Kevin's Roblox Framework. Apply KRF's Jest-Lua test style, Luau typing habits, naming conventions, and quality bar. Do not use for production code, documentation, GitHub issues, or generic Roblox help.
---

## Goal

Write tests that prove KRF behavior clearly.

A good KRF unit test should make the expected contract obvious to a reader without requiring them to mentally reverse engineer the implementation.

Prefer tests for:

- observable behavior
- failure behavior
- validation behavior
- stable error results
- ordering guarantees
- cleanup behavior
- idempotency
- regression risks
- meaningful branch coverage

Do not write tests that only exist to touch lines.

## Before Editing Tests

Before adding or changing tests:

1. Read the source file being tested.
2. Read the nearby existing test file.
3. Match the existing test style.
4. Identify the behavior being proven.
5. Add the smallest useful test or test group.

Do not introduce a new test structure unless the existing file already uses that structure.

## Test Naming

Use behavior-focused test names.

Good:

    it("returns false with a stable error when input is missing", function()

    it("rejects invalid input without mutating existing state", function()

    it("rolls back partially created state when setup fails", function()

    it("preserves deterministic order when input order changes", function()

    it("applies defaults only when no explicit value is provided", function()

    it("treats repeated cleanup as a no-op", function()

Bad:

    it("validates input", function()

    it("handles nil", function()

    it("checks the error case", function()

    it("covers the rollback branch", function()

    it("sets the internal flag correctly", function()

## Luau Style

Follow the style already used in KRF tests.

- Use `--!strict` 
- Keep `require` calls at the top. Follow DRY principals.
- Use descriptive local names. Do not use one letter or abbreviated variable names.
- Use explicit local variable types, any KRF object or variable has a type acompanying it.
- Avoid unnecessary helper functions.
- Avoid unnecessary abstraction.
- Prefer simple inline setup when it is easier to read.
- Prefer raw tables for small test data.
- Do not create fixture systems for one-off cases.

## Assertions

Assertions should be direct and contract-level.

Prefer exact expectations when the expected value is known:

    expect(success).toBe(false)
    expect(errorMessage).toBe("SomeStableError")

Avoid vague assertions:

    expect(result).never.toBe(nil)

unless the contract is actually only about presence.

When testing failures, assert both the failure result and the stable error value when one exists.

## Coverage Mindset

When improving coverage, prioritize branches that represent real behavior.

Useful branch tests include:

- valid input vs invalid input
- required value present vs missing
- optional value absent vs present
- duplicate value paths
- repeated call paths
- boundary values
- cleanup after failure
- deterministic ordering paths
- known regression cases

Do not lower coverage thresholds to make tests pass.

Do not add low-value tests just to satisfy coverage if the behavior is not meaningful.

## Editing Rules

When modifying tests:

- keep the diff focused
- preserve the existing file structure
- preserve existing naming patterns
- keep spec files reasonably scoped and easy to scan
- when a spec grows too large or starts mixing unrelated behaviors, split it into multiple focused spec files
- prefer split names like `Module.Area.spec.luau` when grouping by behavior
- avoid unrelated cleanup
- avoid production code changes
- do not rewrite working tests for style only
- add only what is needed for the requested behavior

If production code appears wrong, report the issue instead of silently changing it.

## Running Tests

Run tests from the repository root.
After every unit test edit, run: `npm run test:unit`

Treat this as the default validation command for test work. Do not batch several test edits before validating. Make a focused edit, run the test command, then continue.If the test command fails, stop and fix the failure before making more test changes.

Before calling the work complete, run: `npm test`

Do not invent alternate test commands unless the user explicitly asks.
Do not claim tests pass unless the command was actually run successfully.

## Reporting Back

After editing tests, report:

1. which behavior was covered
2. which test file changed
3. whether tests were run
4. any important behavior still uncovered

Do not claim coverage improved unless coverage was actually run.
