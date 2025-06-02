.DEFAULT_GOAL := debug

debug:
	zig build --summary all

release:
	zig build -Doptimize=ReleaseSmall --summary all

install:
	cp zig-out/bin/zlstatus /usr/local/bin/

uninstall:
	rm /usr/local/bin/zlstatus

.PHONY: debug release install uninstall
