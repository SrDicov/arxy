# Makefile — arxy se edita en lib/*.sh; src/arxy es GENERADO (commiteado
# porque install.sh y packaging/void lo leen del clon sin herramientas).
# Tras tocar lib/: `make src/arxy` y el diff de src/arxy debe estar vacío
# salvo tu cambio (regenerar 2 veces da el mismo sha256).
# shellcheck corre sobre src/arxy GENERADO (los fragmentos sueltos dan
# falsos SC2034/SC2148: vars y shebang viven en otro fragmento).
LIB = lib/00-head.sh lib/10-level.sh \
      lib/20-state.sh lib/21-setup.sh lib/22-gc.sh lib/30-package.sh \
      lib/31-aur.sh lib/32-maintenance.sh \
      lib/35-gpu.sh \
      lib/40-query.sh lib/41-desktop.sh lib/50-run.sh \
      lib/60-detect.sh lib/61-doctor.sh lib/62-json.sh \
      lib/70-help.sh lib/80-bridge.sh lib/zz-dispatch.sh

src/arxy: $(LIB) Makefile
	cat $(LIB) > $@.tmp
	chmod +x $@.tmp
	bash -n $@.tmp
	mv $@.tmp $@

# Daemon host-bridge: binario C aparte (no va en src/arxy).
bridge/arxy-bridged: bridge/arxy-bridged.c
	cc -O2 -Wall -Wextra -Werror -o $@ $<
bridge: bridge/arxy-bridged

.PHONY: check lint test test-all verify sync
check: src/arxy
	bash -n src/arxy install.sh

lint: check
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -S warning src/arxy install.sh; \
	else \
		echo "SKIP: shellcheck no esta instalado"; \
	fi

test: src/arxy
	bash tests/run.sh

test-all: src/arxy
	ARXY_TEST_ALL=1 bash tests/run.sh

verify: lint test
	git diff --exit-code src/arxy
	cmp src/arxy packaging/void/arxy/files/arxy
	cmp config/arxy.conf packaging/void/arxy/files/arxy.conf
	cmp config/arxy.pub packaging/void/arxy/files/arxy.pub

# Copia el generado + conf + pubkey a packaging/void (flujo: editar lib/,
# make sync, commitear todo junto). cp es idempotente por diseño.
sync: src/arxy
	cp src/arxy packaging/void/arxy/files/arxy
	cp config/arxy.conf packaging/void/arxy/files/arxy.conf
	cp config/arxy.pub packaging/void/arxy/files/arxy.pub
