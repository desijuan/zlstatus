.DEFAULT_GOAL := debug

debug:
	zig build --summary all

release:
	zig build -Doptimize=ReleaseSmall --summary all

clean:
	rm -rf .zig-cache zig-out

install:
	cp zig-out/bin/zlstatus /usr/local/bin/

uninstall:
	rm /usr/local/bin/zlstatus

.PHONY: debug release clean install uninstall
