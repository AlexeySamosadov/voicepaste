.PHONY: build install run clean redeploy

BINARY_NAME = VoicePaste
APP_NAME = VoicePaste.app
BUILD_DIR = .build/release
APP_DIR = $(APP_NAME)/Contents

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
	@echo "  open $(APP_NAME)"
	@echo "  # or move to /Applications, then make redeploy"

run: build
	"$(BUILD_DIR)/$(BINARY_NAME)"

redeploy: install
	-launchctl kickstart -k "gui/$$(id -u)/com.alexey.voicepaste" 2>/dev/null || true
	-pkill -x VoicePaste 2>/dev/null || true
	open "$(APP_NAME)"

clean:
	swift package clean
	rm -rf "$(APP_NAME)"
