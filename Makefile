SHELL := /usr/bin/env bash

PACKAGE_NAME := galaxybook-ov02c10-kmod
VERSION_SCRIPT := ./scripts/package-version.sh
SOURCE_DATE_EPOCH_SCRIPT := ./scripts/source-date-epoch.sh
VERSION := $(shell $(VERSION_SCRIPT))
SOURCE_DATE_EPOCH := $(shell $(SOURCE_DATE_EPOCH_SCRIPT))
export SOURCE_DATE_EPOCH
DIST_DIR := dist
RPM_SPEC := packaging/fedora/$(PACKAGE_NAME).spec
RPMBUILD_DIR := .rpmbuild
GENERATED_SPEC := $(RPMBUILD_DIR)/SPECS/$(PACKAGE_NAME).spec
TAR_REPRO_FLAGS := --sort=name --mtime="@$(SOURCE_DATE_EPOCH)" --owner=0 --group=0 --numeric-owner

.PHONY: help build clean export-patch refresh-base dist srpm rpm

help:
	@printf '%s\n' \
		'make build        Build the external module for the running kernel' \
		'make export-patch Regenerate patches/0001-galaxy-book-ov02c10-downstream.patch' \
		'make refresh-base Refresh sources/intel-ipu6/ov02c10.c from the installed Intel IPU6 source RPM' \
		'make dist         Create a source tarball in dist/' \
		'make srpm         Create a source RPM in dist/' \
		'make rpm          Create akmod/meta RPMs and a source RPM in dist/' \
		'make clean        Remove local build artifacts'

build:
	$(MAKE) -C module

clean:
	$(MAKE) -C module clean >/dev/null 2>&1 || true
	rm -rf $(DIST_DIR) $(RPMBUILD_DIR)

export-patch:
	./scripts/export-patch.sh

refresh-base:
	./scripts/refresh-intel-ipu6-base.sh

dist: clean export-patch
	mkdir -p $(DIST_DIR)
	tar \
		--exclude='./.git' \
		--exclude='./dist' \
		--exclude='./.rpmbuild' \
		$(TAR_REPRO_FLAGS) \
		--transform='s,^\./,$(PACKAGE_NAME)-$(VERSION)/,' \
		-czf $(DIST_DIR)/$(PACKAGE_NAME)-$(VERSION).tar.gz \
		.

$(GENERATED_SPEC): $(RPM_SPEC)
	mkdir -p "$(dir $@)"
	sed \
		-e 's/^Version:[[:space:]].*/Version:        $(VERSION)/' \
		-e 's/^Release:[[:space:]].*/Release:        1%{?dist}/' \
		"$<" > "$@"

srpm: dist
	@set -euo pipefail; \
	rm -rf "$(RPMBUILD_DIR)"; \
	mkdir -p "$(RPMBUILD_DIR)"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}; \
	cp "$(DIST_DIR)/$(PACKAGE_NAME)-$(VERSION).tar.gz" "$(RPMBUILD_DIR)/SOURCES/"; \
	$(MAKE) "$(GENERATED_SPEC)"; \
	rpmbuild -bs "$(GENERATED_SPEC)" --define "_topdir $$(pwd)/$(RPMBUILD_DIR)"; \
	cp "$(RPMBUILD_DIR)"/SRPMS/*.src.rpm "$(DIST_DIR)/"

rpm: dist
	@set -euo pipefail; \
	rm -rf "$(RPMBUILD_DIR)"; \
	mkdir -p "$(RPMBUILD_DIR)"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}; \
	cp "$(DIST_DIR)/$(PACKAGE_NAME)-$(VERSION).tar.gz" "$(RPMBUILD_DIR)/SOURCES/"; \
	$(MAKE) "$(GENERATED_SPEC)"; \
	rpmbuild -ba "$(GENERATED_SPEC)" --define "_topdir $$(pwd)/$(RPMBUILD_DIR)"; \
	cp "$(RPMBUILD_DIR)"/SRPMS/*.src.rpm "$(DIST_DIR)/"; \
	find "$(RPMBUILD_DIR)/RPMS" -type f -name '*.rpm' -exec cp {} "$(DIST_DIR)/" \;
