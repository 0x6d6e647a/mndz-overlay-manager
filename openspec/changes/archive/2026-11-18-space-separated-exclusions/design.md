# Design

## Context

The four selecting commands share `excludeTokens` in `CLI.Parser`; it currently splits on commas and trims ASCII whitespace. Package resolution and selection happen downstream. See the proposal for motivation.

## Goals / Non-Goals

**Goals:** Keep the parsing change shared, retain repeatable options, and make the breaking migration clear to operators.

**Non-Goals:** Change target resolution, selection, or supported package atom forms.

## Decisions

- Split each option argument on whitespace and reject an empty result. Use the existing downstream target resolver, so commas remain part of a token and fail as unknown package names. This preserves a clear distinction between option arguments and positional targets.
- Do not accept both delimiters: compatibility with existing manager scripts was considered, but the chosen syntax follows emerge. Retain the repeatable form for lists without shell quoting.
- Document a quoted list and repeated options. An unquoted second word is a positional target, which can change selection. The development and release run recipes must forward the original argument boundaries so the documented quoted form reaches the parser as one value.

## Risks / Trade-offs

- Existing comma-separated invocations fail after upgrading → document migration and exercise the failure in tests.
- Unquoted lists can select an unintended positional target → explain shell quoting in help and README.

## Migration Plan

Replace `--exclude a,b` with `--exclude 'a b'` or `--exclude a --exclude b`. Rollback to the previous version requires restoring comma syntax for multi-token option values.
