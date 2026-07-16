# Architecture Decision Records

Lightweight ADRs for decisions in this repo whose reasoning isn't obvious from
the code/config alone, or that deliberately defer a "more correct" approach
for a later date. Numbered sequentially, never renumbered or deleted --
superseded decisions get a new ADR that says so, following the standard
[Michael Nygard ADR format](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).

| # | Title | Status |
| --- | --- | --- |
| [0001](0001-kagent-tools-shared-service-account.md) | kagent-tools MCP server: shared read-only ServiceAccount, defer per-caller OBO token exchange | Accepted |
