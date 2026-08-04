## ADDED Requirements

### Requirement: Document Sbcl materialize host tools

When the product supports `DepsAndAssets Sbcl` packages, operator documentation (README and/or CONTRIBUTING as appropriate under project-docs rules) SHALL list the additional host tools required to materialize Autolith-style deps assets (at least `sbcl`, `git`, cargo for vendoring, and the documented qlot/quicklisp bootstrap path), distinct from tools required only for reuse.

#### Scenario: README mentions sbcl materialize tools

- **WHEN** an operator reads the update tools documentation after this capability lands
- **THEN** tools needed for Sbcl/Autolith deps materialize are named among language-specific update requirements
