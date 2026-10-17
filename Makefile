APP      = Makstat
SCHEME   = Makstat
CONFIG  ?= Release
BUILD    = build
DERIVED  = $(BUILD)/DerivedData
PRODUCT  = $(DERIVED)/Build/Products/$(CONFIG)/$(APP).app
INSTALL_DIR ?= /Applications

.PHONY: all gen build run install clean tag

all: build

$(APP).xcodeproj: project.yml
	xcodegen generate

gen: $(APP).xcodeproj

build: gen
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

# Tag a release; the Release workflow builds a universal binary and attaches it.
tag:
	@test -n "$(VERSION)" || (echo "usage: make tag VERSION=x.y.z"; exit 1)
	git tag -a "v$(VERSION)" -m "Makstat $(VERSION)"
	git push origin "v$(VERSION)"
