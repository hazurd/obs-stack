SHELL := /usr/bin/env bash
# Every target runs the matching script in this repo; nothing is installed
# globally except the WSL systemd units scripts/exporters.sh writes.
.PHONY: bootstrap cluster exporters deploy targets verify login dashboards up down teardown

bootstrap:   ## download pinned binaries and add the helm repos
	./scripts/bootstrap.sh

cluster:     ## create (or reuse) the kind cluster "obs"
	./scripts/cluster.sh

exporters:   ## install + start the Windows and WSL exporters
	./scripts/exporters.sh

deploy:      ## helm-deploy prometheus-stack, loki, promtail, dashboards, rules
	./scripts/deploy.sh

targets:     ## probe host reachability and wire the scrape configs
	./scripts/host-targets.sh

verify:      ## check every layer end to end
	./scripts/verify.sh

login:       ## print the grafana login and the unauthenticated endpoints
	./scripts/login.sh

dashboards:  ## regenerate monitoring/dashboards/*.json
	python3 scripts/gen-dashboards.py

up:          ## the whole stack, in order
	./scripts/bootstrap.sh
	./scripts/cluster.sh
	./scripts/exporters.sh
	./scripts/deploy.sh
	./scripts/host-targets.sh
	./scripts/verify.sh

down teardown:
	./scripts/teardown.sh
