# Lab 05: RKE2 on Flatcar. `make lab05-<target>` from the repository root, or `make <target>` here.
include ../../versions.env
export

.PHONY: help render up status kubectl addons verify-cluster upgrade-rke2 verify-rke2-upgraded os-update-all verify-os-updated down destroy pin pin-check render-ci
help:
	@echo "render up status addons upgrade-rke2 os-update NODE=<name> os-update-all down destroy"
	@echo "verify-cluster verify-rke2-upgraded verify-os-updated | pin pin-check (artifact hashes) | kubectl ARGS='get nodes'"

render:
	@./scripts/lab05.sh render
up:                    ## boot server + 2 agents on the OLD Flatcar release with RKE2 at the start version
	@./scripts/lab05.sh up
status:
	@./scripts/lab05.sh status
kubectl:
	@./scripts/lab05.sh kubectl $(ARGS)
addons:                ## system-upgrade-controller and kured, from hash-pinned manifests
	@./scripts/lab05.sh addons
verify-cluster:
	@./scripts/verify.sh cluster
upgrade-rke2:          ## apply the SUC plans (server first, then agents, one at a time)
	@./scripts/lab05.sh upgrade-rke2
verify-rke2-upgraded:
	@./scripts/verify.sh rke2-upgraded
os-update:             ## NODE=rke2-agent-0: unfreeze updates on one node and stage the update
	@./scripts/lab05.sh os-update $(NODE)
os-update-all:         ## stage the update on all nodes; kured serialises the reboots
	@for n in rke2-agent-0 rke2-agent-1 rke2-server; do ./scripts/lab05.sh os-update $$n; done
verify-os-updated:
	@./scripts/verify.sh os-updated
down:
	@./scripts/lab05.sh down
destroy:
	@./scripts/lab05.sh destroy
pin:                   ## recompute artifacts.env from upstream (network)
	@./scripts/pin.sh
pin-check:             ## fail if artifacts.env no longer matches upstream (network)
	@./scripts/pin.sh --check

render-ci:             ## render with fixture secrets into ../../build/lab05
	@./scripts/lab05.sh render-ci
