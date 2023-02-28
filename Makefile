.EXPORT_ALL_VARIABLES:

REPO            ?= cluster-manager

# distro for package building (e.g.: xenial, bionic, centos-7-x86_64)
DISTRIBUTION    ?= none
export DISTRIBUTION

RELEASE         ?= 2102
PKG_REVISION    ?= $(shell git describe --tags --always)
PKG_VERSION     ?= $(shell git describe --tags --always | tr - .)
PKG_ID           = cluster-manager-$(PKG_VERSION)
PKG_BUILD        = 1
BASE_DIR         = $(shell pwd)
ERLANG_BIN       = $(shell dirname $(shell which erl))
REBAR           ?= $(BASE_DIR)/rebar3
LIB_DIR          = _build/default/lib
REL_DIR          = _build/default/rel
PKG_VARS_CONFIG  = pkg.vars.config
OVERLAY_VARS    ?= --overlay_vars=rel/vars.config
TEMPLATE_SCRIPT := ./rel/overlay.escript

GIT_URL := $(shell git config --get remote.origin.url | sed -e 's/\(\/[^/]*\)$$//g')
GIT_URL := $(shell if [ "${GIT_URL}" = "file:/" ]; then echo 'ssh://git@git.onedata.org:7999/vfs'; else echo ${GIT_URL}; fi)
ONEDATA_GIT_URL := $(shell if [ "${ONEDATA_GIT_URL}" = "" ]; then echo ${GIT_URL}; else echo ${ONEDATA_GIT_URL}; fi)
export ONEDATA_GIT_URL

.PHONY: upgrade test package

all: rel

##
## Rebar targets
##

get-deps:
	$(REBAR) get-deps

compile:
	$(REBAR) compile

release: compile template
	$(REBAR) release $(OVERLAY_VARS)

upgrade:
	$(REBAR) upgrade --all

clean: relclean pkgclean
	$(REBAR) clean

distclean: clean
	$(REBAR) clean --all

.PHONY: template
template:
	$(TEMPLATE_SCRIPT) rel/vars.config ./rel/files/vm.args.template

##
## Submodules
##

submodules:
	git submodule sync --recursive ${submodule}
	git submodule update --init --recursive ${submodule}


##
## Release targets
##

rel: release

relclean:
	rm -rf $(REL_DIR)/test_cluster
	rm -rf $(REL_DIR)/cluster_manager

##
## Testing targets
##

eunit:
	$(REBAR) do eunit skip_deps=true suites=${SUITES}, cover
## Rename all tests in order to remove duplicated names (add _(++i) suffix to each test)
	@for tout in `find test -name "TEST-*.xml"`; do awk '/testcase/{gsub("_[0-9]+\"", "_" ++i "\"")}1' $$tout > $$tout.tmp; mv $$tout.tmp $$tout; done

##
## Dialyzer targets local
##

# Dialyzes the project.
dialyzer:
	@./bamboos/scripts/run-with-surefire-report.py \
		--test-name Dialyze \
		--report-path test/dialyzer_results/TEST-dialyzer.xml \
		$(REBAR) dialyzer

##
## Packaging targets
##

check_distribution:
ifeq ($(DISTRIBUTION), none)
	@echo "Please provide package distribution. Oneof: 'xenial', 'bionic', 'centos-7-x86_64'"
	@exit 1
else
	@echo "Building package for distribution $(DISTRIBUTION)"
endif

package/$(PKG_ID).tar.gz:
	mkdir -p package
	rm -rf package/$(PKG_ID)
	git archive --format=tar --prefix=$(PKG_ID)/ $(PKG_REVISION) | (cd package && tar -xf -)
	git submodule foreach --recursive "git archive --prefix=$(PKG_ID)/\$$path/ \$$sha1 | (cd \$$toplevel/package && tar -xf -)"
	${MAKE} -C package/$(PKG_ID) get-deps
	for dep in package/$(PKG_ID) package/$(PKG_ID)/$(LIB_DIR)/*; do \
	     echo "Processing dependency: `basename $${dep}`"; \
	     vsn=`git --git-dir=$${dep}/.git describe --tags 2>/dev/null`; \
	     mkdir -p $${dep}/priv; \
	     echo "$${vsn}" > $${dep}/priv/vsn.git; \
	     sed -i'' "s/{vsn,\\s*git}/{vsn, \"$${vsn}\"}/" $${dep}/src/*.app.src 2>/dev/null || true; \
	done
	tar -C package -czf package/$(PKG_ID).tar.gz $(PKG_ID)

dist: package/$(PKG_ID).tar.gz
	cp package/$(PKG_ID).tar.gz .

package: check_distribution package/$(PKG_ID).tar.gz
	${MAKE} -C package -f $(PKG_ID)/node_package/Makefile

pkgclean:
	rm -rf package

codetag-tracker:
	@./bamboos/scripts/run-with-surefire-report.py \
		--test-name CodetagTracker \
		--report-path test/codetag_tracker_results/TEST-codetag_tracker.xml \
		./bamboos/scripts/codetag-tracker.sh --branch=${BRANCH} --excluded-dirs=node_package
