# Lab 03: build and load a custom system extension. `make lab03-<target>` from the repo root.
include ../../versions.env
export

ROOT := $(abspath ../..)
FIXTURE_KEY := ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureFixtureFixtureFixtureFixtureFixture lab-ci

.PHONY: help build test up verify upgrade-manual upgrade-sysupdate ssh console down destroy render-ci
help:
	@echo "targets: build test up verify upgrade-manual upgrade-sysupdate ssh console down destroy render-ci"

test:                ## unit tests for the extension's payload program
	cd $(ROOT) && GOTOOLCHAIN=local go test ./labs/03-sysext/...
build: test          ## build v1 and v2 extension images into out/
	./scripts/build-sysext.sh v1
	./scripts/build-sysext.sh v2
up:                  ## serve the images and boot the VM with v1
	@./scripts/lab03.sh up
verify:              ## check the extension is merged and working (v1)
	@./scripts/lab03.sh verify v1
upgrade-manual:      ## swap to v2 by hand and re-verify
	@./scripts/lab03.sh upgrade-manual
upgrade-sysupdate:   ## experimental: swap to v2 with systemd-sysupdate
	@./scripts/lab03.sh upgrade-sysupdate
ssh:
	@. ../lib/qemu.sh; LAB_DIR=$$(pwd) vm_ssh lab03 || true
console:
	@cat .state/vms/lab03/console.log
down:
	@./scripts/lab03.sh down
destroy:
	@./scripts/lab03.sh destroy

render-ci: build     ## render with fixture values into ../../build/lab03
	@mkdir -p $(ROOT)/build/lab03
	$(ROOT)/tools/bin/nodegen -inventory inventory.yaml -template butane/node.bu.tmpl \
		-out $(ROOT)/build/lab03 -transpile -var 'ssh_pubkey=$(FIXTURE_KEY)'
