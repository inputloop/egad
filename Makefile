# egad -- everything derives from tokens/egad-tokens.json
PY ?= python3
EMACS ?= emacs

.PHONY: all gate emit archive jit site check clean serve-public serve-trusted

all: site

gate:
	$(PY) tokens/tokens_check.py tokens/egad-tokens.json

emit: gate
	$(PY) emit/emit.py

jit:
	$(PY) jit/unpack.py jit/treatments/*.org --out dist/jit
	cp jit/index.html dist/jit/index.html

archive: emit
	$(PY) archive/make-archive.py dist/elpa-src dist/site/elpa $(if $(SIGN),--sign $(SIGN)) --url $(URL)

# dist/site is what a public node serves; dist/ (one level up) is what a trusted node serves
site: archive jit
	mkdir -p dist/site/org dist/site/keys
	cp dist/org-html/egad.css org-html/*.setup dist/site/org/
	@echo "dist/site ready (unsigned unless SIGN=KEYID was given)"

check: gate
	$(PY) tokens/tokens_check.py --selftest
	$(PY) emit/emit.py >/dev/null
	$(EMACS) --batch -Q -l ert -l tests/egad-tokens-test.el -f ert-run-tests-batch-and-exit
	sh tests/archive-roundtrip.sh
	sh tests/jit-check.sh
	@echo; echo "ALL CHECKS PASSED"

serve-public:
	$(PY) archive/egad-node.py serve egad-node.conf

serve-trusted:
	$(PY) archive/egad-node.py serve egadjit-node.conf

clean:
	rm -rf dist tests/tmp tests/tmp-jit tests/tmp-run.log
	find . -name '*.elc' -delete

URL ?= https://egad.example/
