# Feature: {Name}

- Ticket: {key, or "none"}
- Branch: `{branch name, per the project's convention}`

## Overview
{What and why - from the ticket / request.}

## Acceptance criteria
- [ ] {criterion - from the ticket, never invented}

## What it touches (verified by reading the code)
- `{path}` - {role / why it matters}

### State & data
- **Server data**: {the existing query/endpoint this uses, or the new one and where it goes}
- **Backend contract**: {per endpoint: backend route file:line, router prefix / auth = consumer, handler rules inherited, response vs declared type, backend ticket + real status; or "no API touchpoints"}
- **Backend-derived values**: {every value the UI computes that the backend also computes (prices, fees, totals, availability, policy outcomes) + where the backend computes it; every backend ticket this leans on with its status verified in the backend repo (commit / merged PR), not only in the tracker; or "none". A confirmed gap = promotion condition on the ticket + blocked status when money is involved}
- **Local UI state**: {the existing store slice, or the new one and where it goes}
- **Types**: {where the shared types live}

### UI
- **Screen(s)**: {paths}
- **Reused components**: {from the design system / component registry}
- **New components** (if any): {paths - and where they must be registered}

## Implementation checkpoints

### Checkpoint 1: Structure + types + data wiring
- [ ] {files to create, types, endpoint / slice}
- Commit: `{commit message per the project's convention}`

### Checkpoint 2: {Name}
- [ ] {tasks}
- Commit: `{commit message}`

## Edge cases
- {case}: {handling}

## Open questions
- {only genuine unknowns - remove each one as it gets answered}
