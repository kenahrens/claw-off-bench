SHELL := /bin/bash

.PHONY: setup setup-secrets check-secrets sync-workspace setup-egress build-zeroclaw-adapter bootstrap clean-bench setup-stage compare bench-help bench-init bench-smoke bench-run bench-reset bench-report tasks easy eval factory easy-matrix matrix-preflight deploy-daemon submit-daemon-task remove-daemon run run-matrix collect score

setup:
	kubectl apply -f k8s/base/namespace.yaml
	kubectl apply -f k8s/base/pvc.yaml
	kubectl apply -f k8s/base/networkpolicy.yaml
	@echo "Run make setup-secrets and make sync-workspace before benchmark jobs."

setup-secrets:
	./scripts/setup-secrets.sh

check-secrets:
	./scripts/check-cluster-secrets.sh

sync-workspace:
	./scripts/sync-workspace.sh

setup-egress:
	./scripts/apply-egress-policy.sh

build-zeroclaw-adapter:
	eval "$$(minikube docker-env)" && docker build -t zeroclaw-adapter:latest adapters/zeroclaw

bootstrap:
	make setup
	@if ! docker image inspect zeroclaw-adapter:latest >/dev/null 2>&1; then make build-zeroclaw-adapter; else echo "zeroclaw-adapter image already present; skipping build"; fi

clean-bench:
	./scripts/clean-bench.sh

setup-stage:
	make setup
	make check-secrets
	make sync-workspace
	make setup-egress
	@if [[ "${AGENT_FILTER}" == "" || ",${AGENT_FILTER}," == *",zeroclaw," ]]; then if ! docker image inspect zeroclaw-adapter:latest >/dev/null 2>&1; then make build-zeroclaw-adapter; else echo "zeroclaw-adapter image already present; skipping build"; fi; fi
	make matrix-preflight

compare:
	./scripts/factory.sh

bench-help:
	@echo "Simple interface:" 
	@echo "  make bench-init   # one-time setup + verify cluster secrets"
	@echo "  make bench-smoke  # cheap canary run (1 task, zeroclaw)"
	@echo "  make bench-run    # full clean end-to-end comparison"
	@echo "  make bench-report # collect + score latest artifacts"
	@echo "  make bench-reset  # clean local/k8s run state"

bench-init:
	make bootstrap
	make check-secrets

bench-smoke:
	make clean-bench
	make setup-stage AGENT_FILTER=zeroclaw
	AGENT_NAME=zeroclaw AGENT_IMAGE=zeroclaw-adapter:latest TASK_REF=TASK_1 REQUIRE_GITHUB_TOKEN=false WAIT_TIMEOUT=$${WAIT_TIMEOUT:-180s} ./scripts/run-task.sh

bench-run:
	make compare

bench-report:
	make collect
	make score

bench-reset:
	make clean-bench

tasks:
	./scripts/list-tasks.sh

deploy-daemon:
	./scripts/deploy-daemon.sh

submit-daemon-task:
	./scripts/submit-daemon-task.sh

remove-daemon:
	./scripts/remove-daemon.sh

run-task-%:
	TASK_REF=TASK_$* ./scripts/run-task.sh

daemon-task-%:
	TASK_REF=TASK_$* ./scripts/submit-daemon-task.sh

easy:
	./scripts/easy-button.sh

eval:
	./scripts/eval.sh

factory:
	./scripts/factory.sh

easy-matrix:
	./scripts/easy-matrix.sh

matrix-preflight:
	PREFLIGHT_ONLY=true ./scripts/run-matrix.sh

run:
	./scripts/run-task.sh

run-matrix:
	./scripts/run-matrix.sh

collect:
	./scripts/collect-logs.sh

score:
	python3 ./scripts/score-results.py
