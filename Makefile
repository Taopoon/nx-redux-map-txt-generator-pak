PAK_NAME := $(shell jq -r .name pak.json)
PAK_TYPE := $(shell jq -r .type pak.json)
PAK_FOLDER := $(shell echo $(PAK_TYPE) | cut -c1)$(shell echo $(PAK_TYPE) | tr '[:upper:]' '[:lower:]' | cut -c2-)s

PUSH_SDCARD_PATH ?= /mnt/SDCARD

# NX Redux only (Trimui Brick / Brick Pro / Smart Pro = tg5040, Smart Pro S = tg5050).
# The UI is native/nxlist, compiled inside the NX Redux workspace by
# .github/workflows/native.yaml so it renders with the launcher's own
# toolkit. CI drops the built nxlist.elf into bin/<platform>/ before this
# runs; a local `make build` without one fetches the last released copy.
ARCHITECTURES := arm64
PLATFORMS := tg5040 tg5050

NXLIST_RELEASE_URL ?= https://github.com/Taopoon/nx-redux-map-txt-generator-pak/releases/latest/download
MINUI_MAP_TXT_CREATOR_VERSION := 0.2.0

clean:
	rm -f bin/*/minui-map-txt-creator || true
	rm -f bin/*/nxlist.elf || true

build: $(foreach platform,$(PLATFORMS),bin/$(platform)/nxlist.elf) $(foreach arch,$(ARCHITECTURES),bin/$(arch)/minui-map-txt-creator)

bin/%/nxlist.elf:
	mkdir -p bin/$*
	curl -f -o bin/$*/nxlist.elf -sSL $(NXLIST_RELEASE_URL)/nxlist-$*.elf
	chmod +x bin/$*/nxlist.elf

bin/%/minui-map-txt-creator:
	mkdir -p bin/$*
	curl -f -o bin/$*/minui-map-txt-creator -sSL https://github.com/josegonzalez/minui-map-txt-creator/releases/download/$(MINUI_MAP_TXT_CREATOR_VERSION)/minui-map-txt-creator-linux-$*
	chmod +x bin/$*/minui-map-txt-creator

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
