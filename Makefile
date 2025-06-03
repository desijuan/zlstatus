.DEFAULT_GOAL := debug

BIN = zlstatus
MODE ?= Wayland

debug:
	zig build -Dmode=$(MODE) --summary all

release:
	zig build -Dmode=$(MODE) -Doptimize=ReleaseSmall --summary all

clean:
	rm -rf .zig-cache zig-out

install:
	cp zig-out/bin/$(BIN) /usr/local/bin/

uninstall:
	rm /usr/local/bin/$(BIN)

.PHONY: debug release clean install uninstall
