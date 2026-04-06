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
