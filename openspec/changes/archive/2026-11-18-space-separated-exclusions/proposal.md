# Proposal

## Why

The CLI accepts comma-separated exclusion lists, whereas emerge uses whitespace-separated lists. Matching emerge makes the familiar syntax work consistently across the manager's selecting commands.

## What Changes

- **BREAKING**: Split each `--exclude` value on whitespace instead of commas for `outdated`, `update`, `gencache`, and `smoke`; comma-separated lists no longer work.
- Continue accepting repeated options and reject empty or whitespace-only values.
- Update command help, operator documentation, and tests to describe and exercise the new syntax.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `package-exclude`: Parse exclusion values as whitespace-separated package tokens.
- `cli-help`: Document the new exclusion syntax in selecting-command help.
- `project-docs`: Document the new exclusion syntax and shell quoting in the README.

## Impact

The shared CLI parser, parser tests, help text, and README are affected. Existing scripts using comma-separated values must change. Package resolution and selection remain unchanged.

## Non-goals

- Adding emerge atom, wildcard, slot, or short-option support.
- Changing positional targets, package selection, or version selection.
