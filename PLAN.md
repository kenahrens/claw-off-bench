# Implementation Plan

- [x] Review existing Kubernetes scaffold and confirm gaps against the 2026 Claw evaluation goals.
- [x] Add a canonical 5-agent evaluation matrix artifact for repeatable benchmark runs.
- [x] Keep job templates aligned on fair limits (`1 CPU`, `512Mi`) and non-root execution.
- [x] Add configurable command/bin support so each runtime can be invoked without template forks.
- [x] Implement Kubernetes egress cage workflow that enforces allowlisted LLM/GitHub destinations.
- [x] Support optional dependency egress for package registries when explicitly enabled.
- [x] Add matrix orchestration script to run all agents against the task suite with repeat support.
- [x] Update operator workflow in README for setup, egress policy application, single run, matrix run, and log collection.
- [x] Validate changed scripts and manifests in-repo before handoff.
- [x] Add setup hardening to require real credentials and prevent placeholder secret runs.
- [x] Add workspace sync automation so benchmark jobs run against the expected repository contents.
- [x] Add ZeroClaw daemon-mode benchmark track using Kubernetes deployment + service templates.
- [x] Add daemon lifecycle scripts to deploy/pair, submit HTTP tasks, and remove daemon resources.
- [x] Document daemon-mode workflow in README as a separate steady-state benchmark path.
- [x] Add standard task aliases (`TASK_1`, `TASK_2`, ...) for simpler benchmark execution.
- [x] Add make targets for indexed job and daemon task runs without per-run instruction env vars.
- [x] Add an easy-button workflow that performs setup + run with sensible defaults in one command.
- [x] Add an easy matrix workflow that runs setup + matrix execution in one command.
- [x] Add benchmark scoring workflow for success rate, median, and p95 from `results/` artifacts.

## Revised Multi-Agent Plan

- [x] Add matrix preflight to verify each configured agent image is runnable before execution.
- [x] Generate an explicit availability report so unsupported/private images are visible up front.
- [x] Skip unavailable agents by default (with optional strict mode) so comparisons proceed with available agents.
- [x] Expose one-command multi-agent run path that defaults to all configured agents.
- [x] Keep zero-touch command for users while surfacing exactly what still blocks full 5-agent comparisons.

## Automation-First Reset Plan

- [x] Replace ad-hoc env-var driven runs with a single checked-in run profile file (`config/eval.env`) plus one command.
- [x] Add `make factory` to execute end-to-end evaluation: setup -> preflight -> run all agents across 5 standard tasks -> collect -> score.
- [ ] Lock a canonical 5-task suite dedicated to cross-agent comparison (stable IDs, instructions, and repeat defaults).
- [ ] Add agent capability manifest (`config/agents-capabilities.csv`) for command contract, interactive behavior, and required flags per runtime.
- [ ] Add non-interactive safety policy per agent (approval bypass, max tool iterations, timeout policy) so runs do not hang.
- [ ] Add preflight gate that fails early when required images/credentials are missing for the selected comparison mode.
- [ ] Produce a single final comparison artifact (`results/factory-summary.json`) with per-agent pass/fail, success rate, median, p95, and failure reasons.
- [ ] Add a `make doctor` diagnostic to print exactly what is blocking a full 5-agent benchmark before running.
