APP      = Makstat
SCHEME   = Makstat
CONFIG  ?= Release
BUILD    = build
DERIVED  = $(BUILD)/DerivedData
PRODUCT  = $(DERIVED)/Build/Products/$(CONFIG)/$(APP).app
INSTALL_DIR ?= /Applications

.PHONY: all gen build run install clean open-widgets

all: build

$(APP).xcodeproj: project.yml
	xcodegen generate

gen: $(APP).xcodeproj

build: gen
	xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) build | xcbeautify 2>/dev/null || \
	xcodebuild -project $(APP).xcodeproj -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) build -quiet

run: build
	-pkill -x $(APP) || true
	open $(PRODUCT)

install: build
	-pkill -x $(APP) || true
	rm -rf "$(INSTALL_DIR)/$(APP).app"
	cp -R "$(PRODUCT)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/$(APP).app"

clean:
	rm -rf $(BUILD) $(APP).xcodeproj
