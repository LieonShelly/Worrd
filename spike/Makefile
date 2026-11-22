APP_NAME := Worrd
BUILD_DIR := build
APP := $(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app
INSTALL_DIR := $(HOME)/Applications

.PHONY: all build install run url clean

all: build

build:
	xcodegen generate
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) \
		-configuration Debug -derivedDataPath $(BUILD_DIR) build

LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

install: build
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	-$(LSREGISTER) -u "$(APP)" 2>/dev/null
	-find "$(HOME)/Library/Developer/Xcode/DerivedData" -maxdepth 6 -name "$(APP_NAME).app" -path "*Debug*" -exec $(LSREGISTER) -u {} \; 2>/dev/null
	$(LSREGISTER) -f "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "installed → $(INSTALL_DIR)/$(APP_NAME).app"

run: install
	-pkill -x $(APP_NAME)
	open "$(INSTALL_DIR)/$(APP_NAME).app"

url:
	open "worrd://theme"

clean:
	rm -rf $(BUILD_DIR) $(APP_NAME).xcodeproj
