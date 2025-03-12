.EXPORT_ALL_VARIABLES:
.ONESHELL:
.SILENT:

MAKEFLAGS += --no-builtin-rules --no-builtin-variables

default: help

PATH := $(HOME)/.cargo/bin:$(abspath .venv)/bin:$(PATH)

ifneq (,$(wildcard pyproject.toml))
NAME := $(shell yq -p toml -o yaml '.project.name' pyproject.toml)
MODULE := $(shell yq -p toml -o yaml '.project.scripts' pyproject.toml | cut -d':' -f2 | xargs)
VERSION := $(shell yq -p toml -o yaml '.project.version' pyproject.toml)
endif

settings: setup
	$(call header,Settings)
	$(call var,VERSION,$(VERSION))
	$(call var,NAME,$(NAME))
	$(call var,MODULE,$(MODULE))

setup: $(uv_bin) .venv .gitignore data

test: ## Run Python tests
	$(call header,Running Python tests)
	pytest -v

ruff-format:
	ruff format .

ruff-lint:
	ruff check .

lint: ruff-lint ruff-format ## Lint Python code

build: setup ## Build Python package
	uv build --wheel

update: ## Update Python packages
	rm uv.lock
	$(MAKE) uv.lock

clean: ## Reset development environment
	rm -rf .venv requirements.txt build/ dist/ *.egg-info/
	find . -type d -name "__pycache__" -exec rm -rf {} +

run: ## Run Python application
	uv run $(NAME)

uv_bin := $(HOME)/.cargo/bin/uv

$(uv_bin):
	$(call header,uv - Install)
	mkdir -p $(@D)
	curl -LsSf https://astral.sh/uv/install.sh | sh

pyproject.toml:
	uv init --package
	uv add --dev ruff
	uv add --dev pytest

uv.lock: pyproject.toml
	uv sync && touch $(@)

.venv: uv.lock
	uv venv
	uv sync

requirements.txt: uv.lock
	uv pip freeze --exclude-editable --color never >| $(@)

define INIT_PY
from importlib.metadata import version
__version__ = version(__package__)
def main() -> None:
    print(f"Version: {__version__}")
endef

define INIT_MAIN
from . import main
if __name__ == "__main__":
    main()
endef

src-init:
	echo "$$INIT_PY" >| src/$(MODULE)/__init__.py
	echo "$$INIT_MAIN" >| src/$(MODULE)/__main__.py
	ruff format .

.gitignore:
	cat << EOF > $(@)
	**/__pycache__/
	**/data/
	.venv/
	.env
	EOF

data:
	mkdir -p $(@)

version: ## Update version
	$(eval pre_release := $(shell date '+%H%M' | sed 's/^0*//'))
	$(eval version := $(shell date '+%Y.%m.%d.post$(pre_release)'))
	set -e
	sed -i 's/version = "[0-9]\+\.[0-9]\+\.[0-9]\+.*"/version = "$(version)"/' pyproject.toml
	uv sync
	git add --all

commit: lint ## Commit changes
	git add --all
	git commit -m "Patch: $(NAME) v$(VERSION)"

release: lint ## Create GitHub Release
	$(if $(shell git diff --name-only --exit-code),$(error ==> Stage changes <==),)
	$(if $(shell git diff --staged --name-only --exit-code),$(error ==> Commit changes <==),)
	echo -n "$(magenta)Make Release? $(cyan)(yes/no)$(reset)"
	read -p ": " answer && [ "$$answer" = "yes" ] || exit 1
	$(eval version := $(shell date '+%Y.%m.%d'))
	sed -i 's/version = "[0-9]\+\.[0-9]\+\.[0-9]\+.*"/version = "$(version)"/' pyproject.toml
	uv sync
	rm -rf dist/
	uv build --wheel
	gpg --detach-sign dist/*.whl
	git add --all
	git commit -m "Release: $(NAME) v$(version)" || true
	git push origin main
	gh release create $(version) --title "$(version)" --generate-notes ./dist/*.*

###############################################################################
# Colors and Headers
###############################################################################

TERM := xterm-256color

black := $$(tput setaf 0)
red := $$(tput setaf 1)
green := $$(tput setaf 2)
yellow := $$(tput setaf 3)
blue := $$(tput setaf 4)
magenta := $$(tput setaf 5)
cyan := $$(tput setaf 6)
white := $$(tput setaf 7)
reset := $$(tput sgr0)

define header
echo "$(blue)==> $(1) <==$(reset)"
endef

define var
echo "$(magenta)$(1)$(white): $(yellow)$(2)$(reset)"
endef

help:
	echo "$(blue)Usage: $(green)make [recipe]$(reset)"
	echo "$(blue)Recipes:$(reset)"
	awk 'BEGIN {FS = ":.*?## "; sort_cmd = "sort"} /^[a-zA-Z0-9_-]+:.*?## / \
	{ printf "  \033[33m%-10s\033[0m %s\n", $$1, $$2 | sort_cmd; } \
	END {close(sort_cmd)}' $(MAKEFILE_LIST)

prompt:
	printf "$(magenta)Continue $(white)? $(cyan)(yes/no)$(reset)"
	read -p ": " answer && [ "$$answer" = "yes" ] || exit 127
