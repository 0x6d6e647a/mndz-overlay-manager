# Contributing

## Setup and quality gates

See **[README.md](README.md)** for human-oriented bootstrap, day-to-day commands, and the quality pipeline (hk + Cabal-managed tools under `.tools/bin`).

AI coding agents should follow **[AGENTS.md](AGENTS.md)** for the same workflow in a more operational form.

### Quick start

```bash
./scripts/install-dev-tools   # once (and after tool pin bumps)
hk install                    # enable hooks if needed
hk check                      # full blocking gate
```

Strict policy: missing tools fail hooks with a message to run `./scripts/install-dev-tools`. Hooks do not auto-install and do not use global PATH tools.
