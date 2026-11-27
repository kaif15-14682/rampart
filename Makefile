PREFIX ?= /usr/local

.PHONY: test lint demo data install uninstall

test:
	bats tests

lint:
	shellcheck rampart examples/*.sh

demo:
	./examples/demo.sh

data:
	./examples/generate.sh

install:
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 rampart $(DESTDIR)$(PREFIX)/bin/rampart

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/rampart
