# Tasks

## 1. Exclusion syntax and documentation

- [x] 1.1 Update the shared `--exclude` parser to split whitespace, reject empty values, and retain repeatable options; verify parser and selection tests cover all four commands, whitespace, repeated values, comma rejection, and positional targets.
- [x] 1.2 Update command help and README with quoted lists, repeatable options, and migration from commas; verify help tests and examples for all four commands.
- [x] 1.3 Sync the three delta specs to the living specifications and scrub obsolete comma-based requirement titles and examples; verify the resulting specs describe the implemented syntax consistently.

## 2. Integration verification

- [x] 2.1 Run `openspec validate space-separated-exclusions --strict` and `just check` (including `hk check`); resolve failures before marking tasks complete.
