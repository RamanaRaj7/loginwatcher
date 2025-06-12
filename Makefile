.PHONY: all install uninstall clean

BINARY_NAME = loginwatcher
PREFIX ?= /usr/local
FRAMEWORKS = -framework Foundation -framework AppKit -framework CoreGraphics
CFLAGS = -Wall -O2

all: $(BINARY_NAME)

$(BINARY_NAME): $(BINARY_NAME).m
	clang $(CFLAGS) $(FRAMEWORKS) $< -o $@

install: $(BINARY_NAME)
	install -d $(PREFIX)/bin
	install -m 755 $(BINARY_NAME) $(PREFIX)/bin/$(BINARY_NAME)
	@echo "Installed $(BINARY_NAME) to $(PREFIX)/bin/$(BINARY_NAME)"
	@echo "To start at login, run:"
	@echo "  mkdir -p ~/Library/LaunchAgents"
	@echo "  cp homebrew.mxcl.loginwatcher.plist ~/Library/LaunchAgents/"
	@echo "  launchctl load ~/Library/LaunchAgents/homebrew.mxcl.loginwatcher.plist"

uninstall:
	rm -f $(PREFIX)/bin/$(BINARY_NAME)
	@echo "To stop and remove from startup:"
	@echo "  launchctl unload ~/Library/LaunchAgents/homebrew.mxcl.loginwatcher.plist"
	@echo "  rm ~/Library/LaunchAgents/homebrew.mxcl.loginwatcher.plist"

clean:
	rm -f $(BINARY_NAME) 