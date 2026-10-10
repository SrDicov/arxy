# Makefile — arxy se edita en lib/*.sh; src/arxy* son GENERADOS (commiteados
# porque install.sh y packaging/void los leen del clon sin herramientas).
# src/arxy es el shim (solo lib/zz-dispatch.sh: despacha via exec sin cargar
# nada); src/arxy-<b> concatena sus modulos + trailer lib/exec-<b>.sh.
# Tras tocar lib/: `make build` y el diff de src/ debe estar vacio salvo tu
# cambio (regenerar 2 veces da el mismo sha256).
# shellcheck corre sobre los GENERADOS (los fragmentos sueltos dan falsos
# SC2034/SC2148: vars y shebang viven en otro fragmento).
#
# Mapa de bundles (superset a proposito: incluir de mas nunca rompe, solo
# cuesta parseo; faltar un modulo rompe en runtime):
#   run: run/shell/which. pkg: install/remove/update/__install-file (+aur,
#   gaming, gpu-stack internos). query: info/list/search/search-aur.
#   desktop: export/unexport/desktop. setup: setup/rollback. maint:
#   clean/gc/dedup. doctor: doctor/quickstart/version (+doctor_json y
#   cmd_install para fix --apply: bundle gordo a proposito). bridge:
#   host-bridge. help: help.
# Reglas: todo bundle con ensure_image lleva 21-setup; 21 lleva 10+30
# (cmd_setup via pacman_mut/clean_pkg_cache); 20 lleva 62 (write_version);
# 32 lleva 31 (check_pkg_name); cpu/gpu/detect (60,35) donde se llamen.

SHIM = lib/zz-dispatch.sh

B_run = lib/00-head.sh lib/10-level.sh lib/20-state.sh lib/21-setup.sh \
        lib/30-package.sh lib/35-gpu.sh lib/50-run.sh lib/60-detect.sh \
        lib/62-json.sh lib/80-bridge.sh lib/exec-run.sh
B_pkg = lib/00-head.sh lib/10-level.sh lib/20-state.sh lib/21-setup.sh \
        lib/30-package.sh lib/31-aur.sh lib/32-maintenance.sh \
        lib/35-gpu.sh lib/41-desktop.sh lib/60-detect.sh lib/62-json.sh \
        lib/exec-pkg.sh
B_query = lib/00-head.sh lib/10-level.sh lib/20-state.sh lib/21-setup.sh \
        lib/30-package.sh lib/40-query.sh lib/62-json.sh lib/exec-query.sh
B_desktop = lib/00-head.sh lib/10-level.sh lib/20-state.sh lib/21-setup.sh \
        lib/30-package.sh lib/31-aur.sh lib/41-desktop.sh lib/62-json.sh \
        lib/exec-desktop.sh
B_setup = lib/00-head.sh lib/10-level.sh lib/20-state.sh lib/21-setup.sh \
        lib/30-package.sh lib/35-gpu.sh lib/60-detect.sh lib/61-doctor.sh \
        lib/62-json.sh lib/exec-setup.sh
B_maint = lib/00-head.sh lib/10-level.sh lib/20-state.sh lib/21-setup.sh \
        lib/22-gc.sh lib/30-package.sh lib/31-aur.sh lib/32-maintenance.sh \
        lib/62-json.sh lib/exec-maint.sh
B_doctor = lib/00-head.sh lib/10-level.sh lib/20-state.sh lib/21-setup.sh \
        lib/30-package.sh lib/31-aur.sh lib/32-maintenance.sh \
        lib/35-gpu.sh lib/41-desktop.sh lib/60-detect.sh lib/61-doctor.sh \
        lib/62-json.sh lib/80-bridge.sh lib/exec-doctor.sh
B_bridge = lib/00-head.sh lib/80-bridge.sh lib/exec-bridge.sh
B_help = lib/00-head.sh lib/70-help.sh lib/exec-help.sh

BUNDLES = run pkg query desktop setup maint doctor bridge help
BINS = src/arxy $(BUNDLES:%=src/arxy-%)

src/arxy: $(SHIM) Makefile
	cat $(SHIM) > $@.tmp
	chmod +x $@.tmp
	bash -n $@.tmp
	mv $@.tmp $@

src/arxy-run: $(B_run) Makefile
	cat $(B_run) > $@.tmp
	chmod +x $@.tmp
	bash -n $@.tmp
	mv $@.tmp $@

src/arxy-pkg: $(B_pkg) Makefile
	cat $(B_pkg) > $@.tmp
	chmod +x $@.tmp
	bash -n $@.tmp
	mv $@.tmp $@

src/arxy-query: $(B_query) Makefile
	cat $(B_query) > $@.tmp
	chmod +x $@.tmp
	bash -n $@.tmp
	mv $@.tmp $@

src/arxy-desktop: $(B_desktop) Makefile
	cat $(B_desktop) > $@.tmp
	chmod +x $@.tmp
	bash -n $@.tmp
	mv $@.tmp $@

src/arxy-setup: $(B_setup) Makefile
	cat $(B_setup) > $@.tmp
	chmod +x $@.tmp
	bash -n $@.tmp
	mv $@.tmp $@

src/arxy-maint: $(B_maint) Makefile
	cat $(B_maint) > $@.tmp
	chmod +x $@.tmp
	bash -n $@.tmp
	mv $@.tmp $@

src/arxy-doctor: $(B_doctor) Makefile
	cat $(B_doctor) > $@.tmp
	chmod +x $@.tmp
	bash -n $@.tmp
	mv $@.tmp $@

src/arxy-bridge: $(B_bridge) Makefile
	cat $(B_bridge) > $@.tmp
	chmod +x $@.tmp
	bash -n $@.tmp
	mv $@.tmp $@

src/arxy-help: $(B_help) Makefile
	cat $(B_help) > $@.tmp
	chmod +x $@.tmp
	bash -n $@.tmp
	mv $@.tmp $@

# Daemon host-bridge: binario C aparte (no va en src/arxy*).
bridge/arxy-bridged: bridge/arxy-bridged.c
	cc -O2 -Wall -Wextra -Werror -o $@ $<
bridge: bridge/arxy-bridged

.PHONY: build check lint test test-all verify sync
build: $(BINS)

check: build
	bash -n src/arxy* install.sh

lint: check
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -S warning src/arxy* install.sh; \
	else \
		echo "SKIP: shellcheck no esta instalado"; \
	fi

test: build
	bash tests/run.sh

test-all: build
	ARXY_TEST_ALL=1 bash tests/run.sh

# El tracking es por contenido (git status): los bundles nuevos tambien
# deben estar commiteados; un src/ desfasado o sin commitear falla aqui.
verify: lint test
	test -z "$$(git status --porcelain -- src/ packaging/void/arxy/files/ config/)"
	for f in src/arxy*; do cmp "$$f" "packaging/void/arxy/files/$$(basename $$f)"; done
	cmp config/arxy.conf packaging/void/arxy/files/arxy.conf
	cmp config/arxy.pub packaging/void/arxy/files/arxy.pub

# Copia los generados + conf + pubkey a packaging/void (flujo: editar lib/,
# make sync, commitear todo junto). cp es idempotente por diseño.
sync: build
	for f in src/arxy*; do cp "$$f" "packaging/void/arxy/files/$$(basename $$f)"; done
	cp config/arxy.conf packaging/void/arxy/files/arxy.conf
	cp config/arxy.pub packaging/void/arxy/files/arxy.pub
