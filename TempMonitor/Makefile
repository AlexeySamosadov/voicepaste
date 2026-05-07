.PHONY: build install clean run

BINARY_NAME = TempMonitor
APP_NAME = TempMonitor.app
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

run: build
	"$(BUILD_DIR)/$(BINARY_NAME)"

clean:
	swift package clean
	rm -rf "$(APP_NAME)"
