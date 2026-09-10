.PHONY: build install run clean redeploy install-agent uninstall-agent

BINARY_NAME = VoicePaste
APP_NAME = VoicePaste.app
BUILD_DIR = .build/release
APP_DIR = $(APP_NAME)/Contents
LABEL = com.alexey.voicepaste
AGENT_PLIST = $(HOME)/Library/LaunchAgents/$(LABEL).plist
AGENT_TARGET = gui/$(shell id -u)/$(LABEL)

build:
	swift build -c release

install: build
	mkdir -p "$(APP_DIR)/MacOS"
	mkdir -p "$(APP_DIR)/Resources"
	cp "$(BUILD_DIR)/$(BINARY_NAME)" "$(APP_DIR)/MacOS/$(BINARY_NAME)"
	cp Info.plist "$(APP_DIR)/Info.plist"
	codesign --force --sign - "$(APP_NAME)"
	@echo ""
	@echo "Built $(APP_NAME). To use:"
	@echo "  make redeploy        # (re)start it now"
	@echo "  make install-agent   # start at login + auto-restart after a crash"
	@echo "Note: the ad-hoc signature changes on every build, so macOS asks for"
	@echo "microphone access again on the first recording after a redeploy."

run: build
	"$(BUILD_DIR)/$(BINARY_NAME)"

# Restart the running app with the freshly built binary. Goes through the
# LaunchAgent when it is installed (so launchd keeps supervising it) and
# falls back to pkill + open otherwise. Never stacks a second instance.
redeploy: install
	@if launchctl print "$(AGENT_TARGET)" >/dev/null 2>&1; then \
		echo "Restarting via LaunchAgent $(LABEL)"; \
		launchctl kickstart -k "$(AGENT_TARGET)"; \
	else \
		pkill -x $(BINARY_NAME) 2>/dev/null || true; \
		sleep 1; \
		open "$(APP_NAME)"; \
	fi

# Install the LaunchAgent: launches at login and restarts after a crash.
# Replaces any running instance so exactly one copy is supervised by launchd.
install-agent: install
	mkdir -p "$(HOME)/Library/LaunchAgents"
	sed "s|@APP_PATH@|$(CURDIR)/$(APP_DIR)/MacOS/$(BINARY_NAME)|" \
		launchd/$(LABEL).plist.in > "$(AGENT_PLIST)"
	-launchctl bootout "$(AGENT_TARGET)" 2>/dev/null || true
	-pkill -x $(BINARY_NAME) 2>/dev/null || true
	sleep 1
	launchctl bootstrap "gui/$$(id -u)" "$(AGENT_PLIST)"
	@echo "LaunchAgent $(LABEL) installed: starts at login, restarts after a crash."
	@echo "Stop it for good with: make uninstall-agent"

uninstall-agent:
	-launchctl bootout "$(AGENT_TARGET)" 2>/dev/null || true
	rm -f "$(AGENT_PLIST)"

clean:
	swift package clean
	rm -rf "$(APP_NAME)"
