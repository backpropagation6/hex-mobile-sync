# Hex Mobile Sync — build helpers. Requires Xcode 27.2+ and XcodeGen.
#
#   make project        generate HexMobile.xcodeproj from project.yml
#   make build-device   unsigned build for generic iOS (CI-friendly)
#   make build-sim      unsigned build for the iOS Simulator
#   make test-core      run the HexMobileCore package tests on macOS
#   make test-whisper   run the HexMobileWhisper package tests on macOS (builds WhisperKit)
#   make install-device DEVICE=<udid>   signed build + install on a connected iPhone
#                       (needs DEVELOPMENT_TEAM in Config/Local.xcconfig)
#   make push-whisper-model DEVICE=<udid>   copy the Whisper model and its tokenizer
#                       from build/whisper-models into the app's container on the iPhone
#   make push-whisper-model-sim SIM=<udid>  the same into a simulator's app container

PROJECT      := HexMobile.xcodeproj
SCHEME       := HexMobile
CONFIG       ?= Debug
BUILD_DIR    := build
DERIVED      := $(BUILD_DIR)/DerivedData
DEVICE       ?=
XCODEBUILD   := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED)

# Whisper model for the second final-pass engine (README, "Whisper on the iPhone").
# The app never downloads it: it is copied from the Mac into the app's container.
WHISPER_MODELS_DIR    ?= $(BUILD_DIR)/whisper-models
WHISPER_MODEL         ?= openai_whisper-large-v3-v20240930_turbo_632MB
WHISPER_MODEL_SRC     := $(WHISPER_MODELS_DIR)/models/argmaxinc/whisperkit-coreml/$(WHISPER_MODEL)
WHISPER_TOKENIZER_SRC := $(WHISPER_MODELS_DIR)/tokenizers/models/openai/whisper-large-v3
WHISPER_STAGE         := $(BUILD_DIR)/whisper-stage
WHISPER_REMOTE        := Library/Application Support/whisper
# The prefix of Config/Local.xcconfig wins over Config/Base.xcconfig, as in the build.
BUNDLE_ID_PREFIX_VALUE := $(shell sed -n 's/^BUNDLE_ID_PREFIX[[:space:]]*=[[:space:]]*//p' Config/Base.xcconfig Config/Local.xcconfig 2>/dev/null | tail -1 | tr -d ' \r')
APP_BUNDLE_ID          := $(BUNDLE_ID_PREFIX_VALUE).HexMobile
SIM                   ?=

.PHONY: project build-device build-sim test-core test-whisper install-device clean whisper-stage push-whisper-model push-whisper-model-sim

project:
	xcodegen generate --spec project.yml

$(PROJECT): project.yml
	xcodegen generate --spec project.yml

build-device: $(PROJECT)
	@mkdir -p $(BUILD_DIR)
	set -o pipefail; $(XCODEBUILD) -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tee $(BUILD_DIR)/build-device.log

build-sim: $(PROJECT)
	@mkdir -p $(BUILD_DIR)
	set -o pipefail; $(XCODEBUILD) -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | tee $(BUILD_DIR)/build-sim.log

test-core:
	cd Packages/HexMobileCore && swift test

test-whisper:
	cd Packages/HexMobileWhisper && swift test

install-device: $(PROJECT)
	@if [ -z "$(DEVICE)" ]; then echo "Usage: make install-device DEVICE=<udid>  (list devices: xcrun devicectl list devices)"; exit 2; fi
	@if [ ! -f Config/Local.xcconfig ]; then echo "Missing Config/Local.xcconfig: copy Config/Local.xcconfig.example and set DEVELOPMENT_TEAM"; exit 2; fi
	$(XCODEBUILD) -destination 'id=$(DEVICE)' -allowProvisioningUpdates build
	xcrun devicectl device install app --device $(DEVICE) "$(DERIVED)/Build/Products/$(CONFIG)-iphoneos/HexMobile.app"

# Checks the model on the Mac and gathers the three tokenizer files (the
# download cache next to them is left behind).
whisper-stage:
	@for m in MelSpectrogram AudioEncoder TextDecoder; do \
	  if [ ! -d "$(WHISPER_MODEL_SRC)/$$m.mlmodelc" ]; then echo "Missing $(WHISPER_MODEL_SRC)/$$m.mlmodelc (see README, Whisper on the iPhone)"; exit 2; fi; \
	done
	@for f in tokenizer.json tokenizer_config.json config.json; do \
	  if [ ! -f "$(WHISPER_TOKENIZER_SRC)/$$f" ]; then echo "Missing $(WHISPER_TOKENIZER_SRC)/$$f (see README, Whisper on the iPhone)"; exit 2; fi; \
	done
	@mkdir -p "$(WHISPER_STAGE)/whisper-large-v3"
	@cp -p "$(WHISPER_TOKENIZER_SRC)/tokenizer.json" "$(WHISPER_TOKENIZER_SRC)/tokenizer_config.json" "$(WHISPER_TOKENIZER_SRC)/config.json" "$(WHISPER_STAGE)/whisper-large-v3/"

push-whisper-model: whisper-stage
	@if [ -z "$(DEVICE)" ]; then echo "Usage: make push-whisper-model DEVICE=<udid>  (list devices: xcrun devicectl list devices)"; exit 2; fi
	@if [ -z "$(BUNDLE_ID_PREFIX_VALUE)" ]; then echo "No BUNDLE_ID_PREFIX in Config/*.xcconfig"; exit 2; fi
	xcrun devicectl device copy to --device $(DEVICE) --domain-type appDataContainer --domain-identifier $(APP_BUNDLE_ID) --source "$(WHISPER_MODEL_SRC)" --destination "$(WHISPER_REMOTE)/$(WHISPER_MODEL)"
	xcrun devicectl device copy to --device $(DEVICE) --domain-type appDataContainer --domain-identifier $(APP_BUNDLE_ID) --source "$(WHISPER_STAGE)/whisper-large-v3" --destination "$(WHISPER_REMOTE)/tokenizers/models/openai/whisper-large-v3"
	@echo "Copied. Where it landed (one level; repeat with a deeper --subdirectory):"
	xcrun devicectl device info files --device $(DEVICE) --domain-type appDataContainer --domain-identifier $(APP_BUNDLE_ID) --subdirectory "$(WHISPER_REMOTE)"

# `devicectl` cannot reach a simulator; the container is a folder on the Mac.
push-whisper-model-sim: whisper-stage
	@if [ -z "$(SIM)" ]; then echo "Usage: make push-whisper-model-sim SIM=<udid>  (the app must be installed there)"; exit 2; fi
	@container="$$(xcrun simctl get_app_container $(SIM) $(APP_BUNDLE_ID) data)" && \
	  target="$$container/$(WHISPER_REMOTE)" && \
	  mkdir -p "$$target/$(WHISPER_MODEL)" "$$target/tokenizers/models/openai/whisper-large-v3" && \
	  rsync -a "$(WHISPER_MODEL_SRC)/" "$$target/$(WHISPER_MODEL)/" && \
	  rsync -a "$(WHISPER_STAGE)/whisper-large-v3/" "$$target/tokenizers/models/openai/whisper-large-v3/" && \
	  echo "Copied to $$target" && ls "$$target" "$$target/tokenizers/models/openai/whisper-large-v3"

clean:
	rm -rf $(DERIVED)
