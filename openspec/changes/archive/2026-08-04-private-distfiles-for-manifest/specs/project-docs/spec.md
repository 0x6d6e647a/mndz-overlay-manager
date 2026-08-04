## ADDED Requirements

### Requirement: README documents manager distfiles path and eclean

`README.md` SHALL document:

1. Optional config key `distfiles-path` and global option `--distfiles-path`
2. The default manager distfiles path `${XDG_CACHE_HOME:-$HOME/.cache}/mndz/overlay-manager/distfiles` (or equivalent wording matching implemented resolution)
3. That `update` uses this private DISTDIR for `ebuild … manifest` by default to avoid sticky system `/var/cache/distfiles` ownership clashes
4. The `eclean` work command (purpose: delete the manager distfiles cache; not system Portage distfiles), with at least one example invocation
5. That `eclean` refuses when the effective path is the system Portage DISTDIR

#### Scenario: README catalogs distfiles-path

- **WHEN** an operator reads configuration documentation in `README.md`
- **THEN** the document describes `distfiles-path` and the default XDG cache path

#### Scenario: README catalogs eclean

- **WHEN** an operator reads work commands in `README.md`
- **THEN** the document describes `eclean` with an example invocation and states it does not clean system Portage distfiles
