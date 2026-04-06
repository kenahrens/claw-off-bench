SHELL := /bin/bash

.PHONY: setup setup-secrets sync-workspace setup-egress build-zeroclaw-adapter deploy-daemon submit-daemon-task remove-daemon run run-matrix collect

setup:
	kubectl apply -f k8s/base/namespace.yaml
	kubectl apply -f k8s/base/pvc.yaml
	kubectl apply -f k8s/base/networkpolicy.yaml
	@echo "Run make setup-secrets and make sync-workspace before benchmark jobs."

setup-secrets:
	./scripts/setup-secrets.sh

sync-workspace:
	./scripts/sync-workspace.sh

setup-egress:
	./scripts/apply-egress-policy.sh

build-zeroclaw-adapter:
	eval "$$(minikube docker-env)" && docker build -t zeroclaw-adapter:latest adapters/zeroclaw

deploy-daemon:
	./scripts/deploy-daemon.sh

submit-daemon-task:
	./scripts/submit-daemon-task.sh

remove-daemon:
	./scripts/remove-daemon.sh

run:
	./scripts/run-task.sh

run-matrix:
	./scripts/run-matrix.sh

collect:
	./scripts/collect-logs.sh
