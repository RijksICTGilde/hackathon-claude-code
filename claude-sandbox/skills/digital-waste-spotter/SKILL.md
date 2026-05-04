---
name: digital-waste-spotter
description: analyze code, runtime behavior, logs, traces, profiling output, or architecture notes to identify digital waste that increases energy use, compute cost, latency, memory pressure, or unnecessary resource consumption. use when reviewing unfamiliar code, investigating inefficient runtime behavior, comparing implementation options, or turning waste findings into practical refactors, coding guidelines, and lightweight engineering checks.
---

# Digital Waste Spotter

Analyze software for hidden digital waste: compute, memory, storage, and I/O activity that consumes resources without delivering proportional user or business value.

Focus on runtime behavior over surface-level code style. Treat waste as unnecessary work, unnecessary movement of data, or unnecessary waiting.

## Look for waste patterns such as
- redundant function or service calls
- duplicate computation
- repeated parsing or serialization
- excessive allocations or copying
- over-fetching data
- chatty I/O or network round-trips
- polling instead of event-driven execution
- blocking waits and idle compute
- background work with unclear value
- oversized workloads or poor resource utilization

## Workflow

1. Identify the purpose of the code path or system.
2. Determine where value is created for the user or business.
3. Inspect evidence from code, traces, logs, benchmarks, or profiling output.
4. Spot waste by asking:
  - Is work repeated unnecessarily?
  - Is more data fetched or processed than needed?
  - Are resources active while useful work is low?
  - Is communication fragmented into too many small operations?
5. Explain why the pattern is wasteful in terms of energy, cost, latency, scalability, or operational load.
6. Recommend targeted mitigations with the lowest reasonable implementation effort.
7. Convert findings into reusable team guidance.

## Output format

For each finding, provide:
- title
- waste type
- evidence
- why it is wasteful
- likely impact
- recommended fix
- confidence level

Then include:
- 1 to 3 refactor options with trade-offs
- a validation plan for before/after comparison
- one coding guideline
- one review question
- one lightweight automated check, if feasible

## Rules

- Do not label resource usage as waste unless it lacks proportional value.
- Distinguish intentional trade-offs from accidental inefficiency.
- Be explicit about assumptions when evidence is incomplete.
- Prefer practical fixes over grand redesigns unless the architecture is the main source of waste.
- Prioritize repeated high-volume paths over rare edge cases.

## Preferred tone

Be concrete, skeptical, and practical. Optimize for useful engineering action, not abstract theory.
