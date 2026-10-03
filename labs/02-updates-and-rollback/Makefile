# Lab 02: updates, A/B switch and rollback. `make lab02-<target>` from the repository root.
include ../../versions.env
export

ROOT := $(abspath ../..)
FIXTURE_KEY := ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureFixtureFixtureFixtureFixtureFixture lab-ci

.PHONY: help up status update reboot rollback fail-update verify-baseline verify-updated verify-rolled-back ssh console down destroy render-ci
help:
	@echo "targets: up status update reboot rollback fail-update verify-baseline verify-updated verify-rolled-back ssh console down destroy render-ci"

up:                    ## boot the OLD release with the health gate (GATE=false to disable the gate)
	@./scripts/lab02.sh up
status:                ## version, slots, update_engine state
	@./scripts/lab02.sh status
update:                ## trigger the update and wait until it is staged
	@./scripts/lab02.sh update
reboot:                ## reboot into the new slot and watch it get confirmed
	@./scripts/lab02.sh reboot
rollback:              ## manual rollback with cgpt prioritize
	@./scripts/lab02.sh rollback
fail-update:           ## simulate a bad update and watch the automatic rollback
	@./scripts/lab02.sh fail-update
verify-baseline:
	@./scripts/verify.sh baseline
verify-updated:
	@./scripts/verify.sh updated
verify-rolled-back:
	@./scripts/verify.sh rolled-back
ssh:
	@. ../lib/qemu.sh; LAB_DIR=$$(pwd) vm_ssh lab02 || true
console:
	@cat .state/vms/lab02/console.log
down:
	@./scripts/lab02.sh down
destroy:
	@./scripts/lab02.sh destroy

render-ci:             ## render with fixture values (gate on and off) into ../../build/lab02*
	@mkdir -p $(ROOT)/build/lab02 $(ROOT)/build/lab02-nogate
	$(ROOT)/tools/bin/nodegen -inventory inventory.yaml -template butane/node.bu.tmpl \
		-out $(ROOT)/build/lab02 -transpile -var 'ssh_pubkey=$(FIXTURE_KEY)' -var gate=true
	$(ROOT)/tools/bin/nodegen -inventory inventory.yaml -template butane/node.bu.tmpl \
		-out $(ROOT)/build/lab02-nogate -transpile -var 'ssh_pubkey=$(FIXTURE_KEY)' -var gate=false
