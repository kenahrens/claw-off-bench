SHELL := /bin/bash

.PHONY: setup setup-egress run run-matrix collect

setup:
	kubectl apply -f k8s/base/namespace.yaml
	kubectl apply -f k8s/base/pvc.yaml
	kubectl apply -f k8s/base/networkpolicy.yaml
	@echo "Create and apply k8s/base/secrets.yaml from template before running jobs."

setup-egress:
	./scripts/apply-egress-policy.sh

run:
	./scripts/run-task.sh

run-matrix:
	./scripts/run-matrix.sh

collect:
	./scripts/collect-logs.sh
