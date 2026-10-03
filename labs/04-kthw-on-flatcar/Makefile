# Lab 04: Kubernetes the Hard Way on Flatcar. `make lab04-<target>` from the repository root, or
# `make <target>` here. Targets follow the chapters of kelseyhightower/kubernetes-the-hard-way.
include ../../versions.env
export

ROOT := $(abspath ../..)
FIXTURE_KEY := ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureFixtureFixtureFixtureFixtureFixture lab-ci
FIXTURE_STATE := $(ROOT)/build/lab04/state

.PHONY: help artifacts pki render net-hint up status access verify down destroy ssh-server ssh-node-0 ssh-node-1 native-test render-ci
help:
	@echo "chapter 02  artifacts   download and verify binaries on the jumpbox"
	@echo "chapter 04-06 pki       CA, certificates, kubeconfigs, encryption key"
	@echo "            render      render and transpile the three Ignition configs"
	@echo "chapter 03,07-09 up     boot server, node-0, node-1 (needs the bridge: see net-hint)"
	@echo "chapter 10  access      jumpbox kubeconfig and kubectl"
	@echo "chapter 12  verify      automated smoke test"
	@echo "chapter 13  down | destroy"
	@echo "extra       native-test run the control-plane units natively (no VMs)"

artifacts:             ## KTHW 02
	@./scripts/artifacts.sh
pki:                   ## KTHW 04-06
	@./scripts/pki.sh
render:
	@./scripts/cluster.sh render
net-hint:
	@echo "One-time host setup (root), then start the VMs:"
	@echo "  sudo $(ROOT)/labs/lib/net.sh up"
	@echo "  ./scripts/cluster.sh hosts > /tmp/lab04-hosts && sudo $(ROOT)/labs/lib/net.sh dhcp-start /tmp/lab04-hosts"
up:                    ## KTHW 03, 07, 08, 09
	@./scripts/cluster.sh up
status:
	@./scripts/cluster.sh status
access:                ## KTHW 10
	@./scripts/cluster.sh access
verify:                ## KTHW 12
	@./scripts/smoke.sh
ssh-server ssh-node-0 ssh-node-1:
	@. scripts/env.sh; . ../lib/qemu.sh; vm_ssh $(subst ssh-,,$@)
down:
	@./scripts/cluster.sh down
destroy:               ## KTHW 13
	@./scripts/cluster.sh destroy
native-test:
	@./scripts/native-test.sh

render-ci:             ## render with fixture secrets and stand-in binaries into ../../build/lab04
	@mkdir -p $(ROOT)/build/lab04 $(FIXTURE_STATE)
	LAB04_STATE=$(FIXTURE_STATE) ./scripts/artifacts.sh --fixture
	LAB04_STATE=$(FIXTURE_STATE) ./scripts/pki.sh
	rm -rf $(FIXTURE_STATE)/config && cp -r config $(FIXTURE_STATE)/config
	$(ROOT)/tools/bin/nodegen -inventory inventory.yaml \
		-template server=butane/server.bu.tmpl -template worker=butane/worker.bu.tmpl \
		-partial butane/common.tmpl -base-dir $(FIXTURE_STATE) \
		-out $(ROOT)/build/lab04 -transpile -var 'ssh_pubkey=$(FIXTURE_KEY)'
	echo '--allow-private-keys --max-size 262144' > $(ROOT)/build/lab04/butanecheck.flags
