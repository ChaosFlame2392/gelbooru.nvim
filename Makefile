NVIM     ?= nvim
LUAJIT   ?= luajit
TEST_DIR  = tests

# Run all plenary/busted specs under tests/unit/
# nvim always exits 1 in headless mode; we detect real failures from output.
.PHONY: test
test:
	@$(NVIM) --headless -u $(TEST_DIR)/minimal_init.lua \
		-c "PlenaryBustedDirectory $(TEST_DIR)/unit/ {sequential=true}" 2>&1 | tee /tmp/gelbooru_test.log ; \
	if grep -qE "[1-9][0-9]* failure" /tmp/gelbooru_test.log; then \
		echo "FAILED"; exit 1; \
	else \
		echo "PASSED"; exit 0; \
	fi

# Syntax-check every Lua file with LuaJIT (same runtime as Neovim).
.PHONY: lint
lint:
	@find lua -name '*.lua' | sort | while read f; do \
		$(LUAJIT) -bl "$$f" > /dev/null && echo "OK  $$f" || echo "ERR $$f"; \
	done

# Run a single spec file: make spec FILE=tests/unit/util_spec.lua
.PHONY: spec
spec:
	$(NVIM) --headless -u $(TEST_DIR)/minimal_init.lua \
		-c "PlenaryBustedFile $(FILE)" 2>&1

.PHONY: help
help:
	@echo "Targets:"
	@echo "  make test          — run all unit specs"
	@echo "  make lint          — LuaJIT syntax check all source files"
	@echo "  make spec FILE=... — run a single spec file"
