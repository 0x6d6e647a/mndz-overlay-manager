## ADDED Requirements

### Requirement: Concurrent go.mod version probes under work budget

When building version candidates for Go tree-lane planning (resolving `go` directives across upstream tags), the library SHALL allow concurrent go.mod fetches for distinct tags, subject to the process work budget. Probe concurrency SHALL NOT be unbounded relative to that budget. Functional lane selection results SHALL match sequential probing: same ceilings and same set of parseable go_req values yield the same lane targets.

#### Scenario: Multiple tags probed with bounded concurrency

- **WHEN** planning probes go.mod for many upstream versions and the work budget allows more than one unit
- **THEN** more than one go.mod fetch for that plan may be in flight at once, without exceeding the work budget

#### Scenario: Lane selection unchanged by concurrency

- **WHEN** the same ceilings and the same go.mod contents per tag are available
- **THEN** concurrent probing produces the same lane targets as an equivalent sequential probe order would

### Requirement: go.mod cache does not serialize unrelated fetches

A process-local go.mod cache, when used, SHALL NOT hold its mutual-exclusion lock across the network fetch of a cache miss for a key. Concurrent fetches for different cache keys SHALL be allowed to proceed in parallel (subject to the work budget). A cache hit SHALL return the stored result without re-fetching.

#### Scenario: Distinct keys overlap

- **WHEN** two go.mod fetches for different owner/repo/tag/subdir keys miss the cache at the same time
- **THEN** both network fetches may proceed without one waiting for the other solely because of the cache lock

#### Scenario: Cache hit avoids refetch

- **WHEN** a go.mod key was successfully fetched earlier in the process
- **THEN** a later request for the same key uses the cached body and does not perform another network fetch

### Requirement: Planning progress callbacks

Go tree-lane planning used by `outdated` checks and by `update` apply planning SHALL be able to report progress to the caller: when ceiling discovery starts, when version listing starts, when the version list size is known (so a step total can include per-tag probes), and as each go.mod probe completes. Callers that do not supply progress hooks SHALL still obtain correct plans.

#### Scenario: Step total includes probes after list

- **WHEN** planning obtains a non-empty list of upstream versions and progress hooks are supplied
- **THEN** the caller is informed of a step total that accounts for ceiling discovery, version listing, and one step per version probe (or an equivalent monotone scheme that advances through those phases)

#### Scenario: Hooks optional

- **WHEN** planning runs without progress hooks
- **THEN** planning still returns a correct plan or error and does not require a progress UI
