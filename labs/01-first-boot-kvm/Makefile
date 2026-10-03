# Lab 01: first boot on QEMU. Run via `make lab01-<target>` from the repository root, or
# `make <target>` from this directory.
include ../../versions.env
export

ROOT := $(abspath ../..)
STATE := .state
FIXTURE_KEY := ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureFixtureFixtureFixtureFixtureFixture lab-ci

.PHONY: help up wait ssh verify explore console down destroy render-ci
help:
	@echo "targets: up wait ssh verify explore console down destroy render-ci"

up:       ## fetch image, render config, boot the VM
	@./scripts/up.sh

ssh:      ## ssh into the VM as core
	@. ../lib/qemu.sh; LAB_DIR=$$(pwd) vm_ssh lab01 || true

verify:   ## assert the lab's properties
	@./scripts/verify.sh

explore:  ## print the outputs the README walks through
	@./scripts/explore.sh

console:  ## show the serial console log
	@cat $(STATE)/vms/lab01/console.log

down:     ## power off (disk kept)
	@. ../lib/qemu.sh; LAB_DIR=$$(pwd) vm_stop lab01

destroy:  ## delete the VM and all lab state
	@. ../lib/qemu.sh; LAB_DIR=$$(pwd) vm_destroy lab01; rm -rf $(STATE)

render-ci: ## render with fixture values into ../../build/lab01 (used by `make check`)
	@mkdir -p $(ROOT)/build/lab01
	$(ROOT)/tools/bin/nodegen -inventory inventory.yaml -template butane/node.bu.tmpl \
		-out $(ROOT)/build/lab01 -transpile -var 'ssh_pubkey=$(FIXTURE_KEY)'
