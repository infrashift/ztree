# ztree development gates. Plain GNU Make syntax. The ZMakefile has the same targets.

ZIG ?= zig
PYTHON ?= python3
GO ?= go
GOFMT ?= $(shell $(GO) env GOROOT)/bin/gofmt
ZIG_SOURCES := build.zig build.zig.zon src tests tools
# lexis checks the documentation with vocabulary.cue when it is on the PATH (ADR-0018).
LEXIS ?= lexis
# The docs-lexis task reads these files with the vocabulary of this repository.
# Each finding fails it.
DOCS_LEXIS_PATHS := CLAUDE.md PLAN.md .okfw
DOCS_LEXIS_FLAGS := --ruleset ste-100 --ruleset vocabulary.cue --fail-on note \
	--exclude .okfw/daily --exclude .okfw/ephemeral --exclude index.md --exclude log.md

.PHONY: check build lib test conformance differential query-diff go lint fmt wiki docs-style docs-lexis

## check: run every gate (the default goal)
check: lint test conformance differential query-diff go wiki docs-style docs-lexis

## build: compile the library into zig-out
build:
	$(ZIG) build

## lib: write the static library and the C header to zig-out (ReleaseSafe)
lib:
	$(ZIG) build lib --release

## go: check the format of the Go binding, vet it and test it with the race detector
go: lib
	$(GOFMT) -l bindings/go | (! grep .)
	cd bindings/go && $(GO) vet ./...
	cd bindings/go && $(GO) test -race -count=1 ./...

## test: run the unit tests
test:
	$(ZIG) build test --summary all

## conformance: check each grammar corpus example against its expected tree
conformance:
	$(ZIG) build conformance --summary all

## differential: parse the source files of this repository with ztree and the reference runtime
differential:
	$(ZIG) build differential --summary all

## query-diff: compare the query matches with the reference query cursor
query-diff:
	$(ZIG) build query-diff --summary all

## lint: check the formatting and the Power of 10 rules
lint:
	$(ZIG) fmt --check $(ZIG_SOURCES)
	$(PYTHON) -I scripts/nasa-lint.py

## fmt: format the Zig sources in place
fmt:
	$(ZIG) fmt $(ZIG_SOURCES)

## wiki: validate the OKF wiki
wiki:
	okfw validate --all
	okfw validate --okf

## docs-style: check the documentation against ASD-STE100 rules
docs-style:
	$(PYTHON) -I scripts/ste-check.py

## docs-lexis: check the documentation with lexis and vocabulary.cue, when lexis is on the PATH (each finding fails)
docs-lexis:
	if command -v $(LEXIS) >/dev/null 2>&1; then $(LEXIS) scan $(DOCS_LEXIS_FLAGS) $(DOCS_LEXIS_PATHS); else echo "docs-lexis: $(LEXIS) not found, so scripts/ste-check.py checks the documentation alone"; fi
