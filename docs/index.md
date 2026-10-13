# Project knowledge

## Purpose and authority

This index maps brygga's durable, checked-in project knowledge.

- [`README.md`](../README.md) is the public contract: installation, setup,
  commands and behavior.
- [`AGENTS.md`](../AGENTS.md) holds contributor rules and validation.
- Code and [`tests/headless.lua`](../tests/headless.lua) anchor claims about
  implemented behavior.

## Current-state documentation

- [Claude Code IDE protocol](protocol.md): discovery, transport, the call
  sequence the CLI uses, openDiff replies, the notifications brygga sends and
  how far they are verified, and how to test against the real CLI.

## Decision history

No decision records yet. Add a numbered record under `docs/decisions/` only
for accepted, non-obvious rationale that the current-state documents, a
project rule or a test cannot express.

## Maintenance

Update `protocol.md` in the same change as code that alters protocol behavior,
and re-date its verification line when it is re-checked against a newer
Claude Code. Do not retain session logs or one-off probe scripts.
