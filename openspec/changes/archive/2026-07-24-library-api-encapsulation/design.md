## Context

Part 5 of 8. The library exposes all modules; weeder roots almost everything; test-only Apply hooks look like product API. After the Apply split, the module map is stable enough to define a real boundary.

## Goals / Non-Goals

**Goals:**

- Clearer public vs internal surface for the application library.
- Weeder roots reflect real entry points, not “every module.”
- Tests and executable keep building.
- Document policy only if AGENTS/CONTRIBUTING need weeder/export guidance updates.

**Non-Goals:**

- Hackage publication or semver API promises.
- Forcing all tests through full CLI process integration only.
- Multi-package workspace split unless single-library approach fails.

## Decisions

### D1: Preferred strategy — Option C (single library, honest exports)

**Choice:** Keep one library stanza. Set `exposed-modules` to modules needed by `app/Main.hs` **and** by the test-suite (tests depend on the library). Move pure implementation detail modules that neither Main nor tests import into `other-modules` when possible. Prefer explicit export lists on modules that remain exposed.

**Rationale:** Avoids multi-library cabal complexity while still documenting that this is not a third-party API. Full “hide everything tests use” is impossible without a second internal library.

### D2: Optional stretch — internal library stanza

**Choice:** If Option C still leaves nearly all modules exposed because tests import them, document that fact and tighten **weeder** primarily; optional follow-up multi-stanza is out of default scope unless easy.

### D3: Weeder roots

**Choice:**

```toml
roots = [ "^Main\\.main$", "^Paths_…"]
```

Use `root-modules` only for modules that are intentionally public and may have unused exports for a stable surface — **or** drop blanket root-modules and accept weeder deleting unused exports (preferred after tests cover real use).

**Rationale:** Audit: blanket root-modules defeat weeder.

### D4: Test-only Apply hooks

**Choice:** Group legacy test wrappers under clear names / a dedicated module (e.g. `Update.Apply.TestSupport`) imported only by tests, or keep thin re-exports on `Update.Apply` with Haddock “test support” notes. Prefer not advertising them in README.

### D5: Docs

**Choice:** Update AGENTS.md only if agent weeder guidance changes (e.g. “do not re-add blanket root-modules”). Update CONTRIBUTING if contributor weeder policy is documented there.

## Risks / Trade-offs

- **[Risk] Hiding a module breaks tests or Main** → Mitigation: derive export set from actual imports (`app/Main.hs`, `test/**`); compile after each trim.
- **[Risk] Weeder suddenly flags many unused exports** → Mitigation: delete true dead code or justify roots; do not silently re-blanket.
- **[Risk] Over-scoping into multi-package** → Mitigation: Option C default.

## Migration Plan

1. Inventory imports from app + tests.
2. Adjust cabal exposed/other-modules.
3. Tighten weeder.toml; fix fallout.
4. Clarify test hooks.
5. Docs if needed; `hk check`.

Rollback: restore cabal + weeder.toml.

## Open Questions

None blocking — exact final exposed list is inventory-driven at apply time.
