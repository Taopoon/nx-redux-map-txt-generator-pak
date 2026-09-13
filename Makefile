PAK_NAME := $(shell jq -r .name pak.json)
PAK_TYPE := $(shell jq -r .type pak.json)
PAK_FOLDER := $(shell echo $(PAK_TYPE) | cut -c1)$(shell echo $(PAK_TYPE) | tr '[:upper:]' '[:lower:]' | cut -c2-)s

PUSH_SDCARD_PATH ?= /mnt/SDCARD

# NX Redux only (Trimui Brick / Brick Pro / Smart Pro = tg5040, Smart Pro S = tg5050).
# NX Redux is a NextUI fork, so the "-nextui" builds of minui-list /
# minui-presenter are used: they follow the device theme and link against
# NextUI's libmsettings.
ARCHITECTURES := arm64
PLATFORMS := tg5040 tg5050
UI_SUFFIX := -nextui

MINUI_LIST_VERSION := 0.15.1
MINUI_PRESENTER_VERSION := 0.13.1
MINUI_MAP_TXT_CREATOR_VERSION := 0.2.0

clean:
	rm -f bin/*/minui-map-txt-creator || true
	rm -f bin/*/minui-list || true
	rm -f bin/*/minui-presenter || true

build: $(foreach platform,$(PLATFORMS),bin/$(platform)/minui-list bin/$(platform)/minui-presenter) $(foreach arch,$(ARCHITECTURES),bin/$(arch)/minui-map-txt-creator)

bin/%/minui-list:
	mkdir -p bin/$*
	curl -f -o bin/$*/minui-list -sSL https://github.com/josegonzalez/minui-list/releases/download/$(MINUI_LIST_VERSION)/minui-list-$*$(UI_SUFFIX)
	chmod +x bin/$*/minui-list

bin/%/minui-map-txt-creator:
	mkdir -p bin/$*
	curl -f -o bin/$*/minui-map-txt-creator -sSL https://github.com/josegonzalez/minui-map-txt-creator/releases/download/$(MINUI_MAP_TXT_CREATOR_VERSION)/minui-map-txt-creator-linux-$*
	chmod +x bin/$*/minui-map-txt-creator

bin/%/minui-presenter:
	mkdir -p bin/$*
	curl -f -o bin/$*/minui-presenter -sSL https://github.com/josegonzalez/minui-presenter/releases/download/$(MINUI_PRESENTER_VERSION)/minui-presenter-$*$(UI_SUFFIX)
	chmod +x bin/$*/minui-presenter

release: build
	mkdir -p dist
	git archive --format=zip --output "dist/$(PAK_NAME).pak.zip" HEAD
	while IFS= read -r file; do zip -r "dist/$(PAK_NAME).pak.zip" "$$file"; done < .gitarchiveinclude
	$(MAKE) bump-version
	zip -r "dist/$(PAK_NAME).pak.zip" pak.json
	ls -lah dist

bump-version:
	jq '.version = "$(RELEASE_VERSION)"' pak.json > pak.json.tmp
	mv pak.json.tmp pak.json

# NX Redux resolves user paks flat: /Tools/<Name>.pak (no platform subfolder)
push: release
	rm -rf "dist/$(PAK_NAME).pak"
	cd dist && unzip "$(PAK_NAME).pak.zip" -d "$(PAK_NAME).pak"
	adb push "dist/$(PAK_NAME).pak/." "$(PUSH_SDCARD_PATH)/$(PAK_FOLDER)/$(PAK_NAME).pak"
