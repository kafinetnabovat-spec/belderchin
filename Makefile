# Belderchin build helpers (Android only).
#
# The Go core is NOT built here: we download the exact prebuilt hiddify-core
# release that upstream Hiddify shipped with the app version we forked, and we
# verify its SHA256 before it can be linked into the APK.
include dependencies.properties

ANDROID_OUT := android/app/libs
CORE_RELEASE := v$(core.version)
CORE_URL := https://github.com/hiddify/hiddify-core/releases/download/$(CORE_RELEASE)/hiddify-lib-android.tar.gz
CORE_TARBALL := $(ANDROID_OUT)/hiddify-lib-android.tar.gz

# lib/main_prod.dart disables dev-only behaviour; lib/main.dart is the dev entry.
CHANNEL ?= prod
ifeq ($(CHANNEL),prod)
	TARGET := lib/main_prod.dart
else
	TARGET := lib/main.dart
endif

.PHONY: help get gen translate prepare android-libs android-apk analyze test secrets-scan clean

help:
	@echo "make prepare       - pub get + code generation + translations + core library"
	@echo "make android-apk   - build release APKs (split per ABI + universal) into build/app/outputs"
	@echo "make analyze       - flutter analyze"
	@echo "make test          - flutter test"
	@echo "make secrets-scan  - fail if anything that looks like a secret is tracked by git"

get:
	flutter pub get

gen:
	dart run build_runner build --delete-conflicting-outputs

translate:
	dart run slang

prepare: get gen translate android-libs

# Download + verify the prebuilt core. The checksum is pinned in dependencies.properties.
android-libs:
	@mkdir -p $(ANDROID_OUT)
	@if [ ! -f "$(ANDROID_OUT)/hiddify-core.aar" ]; then \
		echo "Downloading hiddify-core $(CORE_RELEASE) ..."; \
		curl -fsSL "$(CORE_URL)" -o "$(CORE_TARBALL)"; \
		echo "$(core.android.sha256)  $(CORE_TARBALL)" | sha256sum -c - ; \
		tar xzf "$(CORE_TARBALL)" -C "$(ANDROID_OUT)/"; \
		rm -f "$(CORE_TARBALL)"; \
	else \
		echo "hiddify-core.aar already present, skipping download"; \
	fi
	@ls -la $(ANDROID_OUT)

android-apk:
	flutter build apk --release --target=$(TARGET) --split-per-abi
	flutter build apk --release --target=$(TARGET)
	@ls -la build/app/outputs/flutter-apk/

analyze:
	flutter analyze

test:
	flutter test

secrets-scan:
	@bash tools/ci/secrets_scan.sh

clean:
	flutter clean
	rm -rf $(ANDROID_OUT)/hiddify-core.aar
