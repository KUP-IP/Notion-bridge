# Makefile – Notion Bridge
# PKT-329: V1-14b Build System + Connection Setup
# PKT-346: V1-QUALITY-POLISH — Added install and clean-tcc targets
#
# Standard workflow: make clean → make test → make app → make dmg → make release
# Debug workflow:    make debug
# Dev app bundle:    make app (unsigned, for local testing)

APP_NAME        = Notion Bridge
DMG_VOLUME_NAME = NotionBridge
BUNDLE_ID       = kup.solutions.notion-bridge
BINARY_NAME     = NotionBridge
BUILD_DIR       = .build
RELEASE_DIR     = $(BUILD_DIR)/release
DEBUG_DIR       = $(BUILD_DIR)/debug
APP_BUNDLE      = $(BUILD_DIR)/NotionBridge.app
FRAMEWORKS_DIR  = $(APP_BUNDLE)/Contents/Frameworks
VERSION        := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG_NAME        = notion-bridge-v$(VERSION).dmg
DMG_PATH        = $(BUILD_DIR)/$(DMG_NAME)
DMG_STAGING     = $(BUILD_DIR)/dmg-staging
DMG_BACKGROUND  = $(BUILD_DIR)/dmg-background.png
APPCAST_PATH   ?= appcast.xml
APPCAST_ARCHIVES_DIR = $(BUILD_DIR)/sparkle-updates
RELEASE_TAG    ?= v$(VERSION)
APPCAST_FEED_URL ?= https://raw.githubusercontent.com/KUP-IP/Notion-bridge/main/appcast.xml
APPCAST_LINK   ?= https://github.com/KUP-IP/Notion-bridge/releases
APPCAST_DOWNLOAD_URL_PREFIX ?= https://github.com/KUP-IP/Notion-bridge/releases/download/$(RELEASE_TAG)/
SIGNING_ID     ?= Developer ID Application: Isaiah Peters (VP24Z9CS22)
NOTARIZE_PROFILE ?= notarytool-profile
GENERATE_APPCAST ?= 1

INFO_PLIST      = Info.plist
RESOURCES_DIR   = NotionBridge/App/Resources
DMG_ICON        = $(RESOURCES_DIR)/Assets.xcassets/AppIcon.appiconset/icon_512x512.png
SPARKLE_ARTIFACT_DIR = $(BUILD_DIR)/artifacts/sparkle/Sparkle
SPARKLE_FRAMEWORK = $(SPARKLE_ARTIFACT_DIR)/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
SPARKLE_TOOLS_DIR = $(SPARKLE_ARTIFACT_DIR)/bin

.PHONY: debug build test app appcast dmg dmg-background sign notarize verify release clean install clean-tcc

# ── Debug Build ────────────────────────────────────────────────
debug:
	@echo "🔨 Building debug binary..."
	swift build -c debug
	@echo "✅ Debug build: $(DEBUG_DIR)/$(BINARY_NAME)"

# ── Release Build ──────────────────────────────────────────────
build:
	@echo "🔨 Building release binary with strict concurrency..."
	swift build -c release \
		-Xswiftc -strict-concurrency=complete
	@echo "✅ Release build: $(RELEASE_DIR)/$(BINARY_NAME)"

# ── Test ───────────────────────────────────────────────────────
test:
	@echo "🧪 Running test suite..."
	swift build -c debug
	$(DEBUG_DIR)/NotionBridgeTests
	@echo "✅ Tests complete"

# ── App Bundle (.app) ──────────────────────────────────────────
app: build
	@echo "📦 Packaging .app bundle..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@mkdir -p $(FRAMEWORKS_DIR)
	@cp $(RELEASE_DIR)/$(BINARY_NAME) "$(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)"
	@install_name_tool -add_rpath "@executable_path/../Frameworks" "$(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)"
	@cp $(INFO_PLIST) $(APP_BUNDLE)/Contents/Info.plist
	@test -f $(RESOURCES_DIR)/NotionBridge.icns && \
		cp $(RESOURCES_DIR)/NotionBridge.icns $(APP_BUNDLE)/Contents/Resources/ || true
	@for f in $(RESOURCES_DIR)/*.png; do \
		test -f "$$f" && cp "$$f" $(APP_BUNDLE)/Contents/Resources/ || true; \
	done
	@# ── Copy SPM resource bundle to Contents/Resources (where Bundle.module expects it) ──
	@SPM_BUNDLE="$(RELEASE_DIR)/NotionBridge_NotionBridge.bundle"; \
		if [ -d "$$SPM_BUNDLE" ]; then \
			cp -R "$$SPM_BUNDLE" "$(APP_BUNDLE)/Contents/Resources/"; \
			echo "  ↳ Copied SPM resource bundle to .app root"; \
		fi
	@# ── Add MenuBarIcon-named copies for image(forResource:) lookup ──
	@if [ -f "$(APP_BUNDLE)/Contents/Resources/NotionBridge_NotionBridge.bundle/notionbridge-menubar.png" ]; then \
		cp "$(APP_BUNDLE)/Contents/Resources/NotionBridge_NotionBridge.bundle/notionbridge-menubar.png" \
			"$(APP_BUNDLE)/Contents/Resources/NotionBridge_NotionBridge.bundle/MenuBarIcon.png"; \
		cp "$(APP_BUNDLE)/Contents/Resources/NotionBridge_NotionBridge.bundle/notionbridge-menubar@2x.png" \
			"$(APP_BUNDLE)/Contents/Resources/NotionBridge_NotionBridge.bundle/MenuBarIcon@2x.png"; \
		echo "  ↳ Added MenuBarIcon.png + @2x aliases"; \
	fi
	@# ── Copy MenuBarIcon to top-level Contents/Resources for Bundle.main fallback ──
	@if [ -f "$(APP_BUNDLE)/Contents/Resources/notionbridge-menubar.png" ]; then \
		cp "$(APP_BUNDLE)/Contents/Resources/notionbridge-menubar.png" \
			"$(APP_BUNDLE)/Contents/Resources/MenuBarIcon.png"; \
		cp "$(APP_BUNDLE)/Contents/Resources/notionbridge-menubar@2x.png" \
			"$(APP_BUNDLE)/Contents/Resources/MenuBarIcon@2x.png"; \
		echo "  ↳ Added top-level MenuBarIcon.png + @2x for Bundle.main"; \
	fi
	@# ── Compile Assets.xcassets → Assets.car via actool ──
	@XCASSETS="$(APP_BUNDLE)/Contents/Resources/NotionBridge_NotionBridge.bundle/Assets.xcassets"; \
		if [ -d "$$XCASSETS" ]; then \
			actool --compile "$(APP_BUNDLE)/Contents/Resources/NotionBridge_NotionBridge.bundle" \
				--platform macosx --minimum-deployment-target 14.0 \
				--app-icon AppIcon --output-partial-info-plist /dev/null \
				"$$XCASSETS" >/dev/null 2>&1 && \
			echo "  ↳ Compiled Assets.xcassets → Assets.car" || \
			echo "  ⚠️  actool compile failed (menu bar icon may use fallback)"; \
			rm -rf "$$XCASSETS"; \
			echo "  ↳ Cleaned raw .xcassets from bundle"; \
		fi
	@# ── Compile AppIcon from source .xcassets into main Contents/Resources for Notification Center ──
	@SRC_XCASSETS="$(RESOURCES_DIR)/Assets.xcassets"; \
		if [ -d "$$SRC_XCASSETS" ]; then \
			actool --compile "$(APP_BUNDLE)/Contents/Resources" \
				--platform macosx --minimum-deployment-target 14.0 \
				--app-icon AppIcon --output-partial-info-plist /dev/null \
				"$$SRC_XCASSETS" >/dev/null 2>&1 && \
			echo "  ↳ Compiled AppIcon into main Contents/Resources" || \
			echo "  ⚠️  actool AppIcon compile failed"; \
		fi
	@if [ -d "$(SPARKLE_FRAMEWORK)" ]; then \
		cp -R "$(SPARKLE_FRAMEWORK)" "$(FRAMEWORKS_DIR)/"; \
		echo "  ↳ Embedded Sparkle.framework"; \
	else \
		echo "  ⚠️  Sparkle.framework not found at $(SPARKLE_FRAMEWORK)"; \
	fi
	@echo "✅ App bundle: $(APP_BUNDLE)"

# ── Install ────────────────────────────────────────────────────────────
install: notarize
	@echo "📲 Installing notarized app to /Applications..."
	@rm -rf "/Applications/Notion Bridge.app" "/Applications/NotionBridge.app"
	@ditto "$(APP_BUNDLE)" "/Applications/Notion Bridge.app"
	@spctl --assess --verbose "/Applications/Notion Bridge.app"
	@echo "🧹 Clearing launch services cache (preserving TCC grants)..."
	@echo "🔄 Refreshing icon caches..."
	@killall Dock 2>/dev/null || true
	@echo "✅ Installed: /Applications/Notion Bridge.app"

# ── Clean TCC ──────────────────────────────────────────────────────────
clean-tcc:
	@echo "🧹 Resetting TCC for legacy bundle ID (solutions.kup.keepr)..."
	-tccutil reset All solutions.kup.keepr
	@echo "🧹 Resetting TCC for current bundle ID (kup.solutions.notion-bridge)..."
	-tccutil reset All kup.solutions.notion-bridge
	@echo "✅ TCC reset complete — permissions will be re-requested on next launch"

# ── Appcast ───────────────────────────────────────────────────
appcast:
	@command -v "$(SPARKLE_TOOLS_DIR)/generate_appcast" >/dev/null || { echo "❌ Sparkle generate_appcast tool not found"; exit 1; }
	@test -f "$(DMG_PATH)" || { echo "❌ DMG not found at $(DMG_PATH). Run 'make dmg' or build the DMG first."; exit 1; }
	@echo "📰 Generating appcast..."
	@rm -rf "$(APPCAST_ARCHIVES_DIR)"
	@rm -f "$(APPCAST_PATH)"
	@mkdir -p "$(APPCAST_ARCHIVES_DIR)"
	@cp "$(DMG_PATH)" "$(APPCAST_ARCHIVES_DIR)/"
	@"$(SPARKLE_TOOLS_DIR)/generate_appcast" \
		--download-url-prefix "$(APPCAST_DOWNLOAD_URL_PREFIX)" \
		--link "$(APPCAST_LINK)" \
		-o "$(APPCAST_PATH)" \
		"$(APPCAST_ARCHIVES_DIR)"
	@rm -rf "$(APPCAST_ARCHIVES_DIR)"
	@echo "✅ Appcast: $(APPCAST_PATH)"

# ── DMG Background ────────────────────────────────────────────
dmg-background:
	@mkdir -p $(BUILD_DIR)
	@python3 scripts/generate_dmg_background.py "$(DMG_BACKGROUND)" "$(DMG_ICON)"
	@echo "🎨 DMG background: $(DMG_BACKGROUND)"

# ── DMG (disk image) ──────────────────────────────────────────
dmg: notarize dmg-background
	@command -v create-dmg >/dev/null || { echo "❌ create-dmg is required. Install it with: brew install create-dmg"; exit 1; }
	@echo "💿 Creating production DMG..."
	@rm -rf $(DMG_STAGING)
	@mkdir -p $(DMG_STAGING)
	@cp -R "$(APP_BUNDLE)" "$(DMG_STAGING)/"
	@rm -f "$(DMG_PATH)"
	create-dmg \
		--volname "$(DMG_VOLUME_NAME)" \
		--volicon "$(RESOURCES_DIR)/NotionBridge.icns" \
		--background "$(DMG_BACKGROUND)" \
		--window-pos 220 140 \
		--window-size 640 360 \
		--text-size 14 \
		--icon-size 128 \
		--icon "$(notdir $(APP_BUNDLE))" 180 180 \
		--hide-extension "$(notdir $(APP_BUNDLE))" \
		--app-drop-link 460 180 \
		--format UDZO \
		"$(DMG_PATH)" \
		"$(DMG_STAGING)"
	@rm -rf $(DMG_STAGING)
	@echo "🔏 Signing DMG..."
	codesign --force --sign "$(SIGNING_ID)" --timestamp "$(DMG_PATH)"
	@echo "📤 Notarizing DMG..."
	xcrun notarytool submit "$(DMG_PATH)" --keychain-profile "$(NOTARIZE_PROFILE)" --wait
	@echo "📎 Stapling DMG..."
	xcrun stapler staple "$(DMG_PATH)"
	@echo "🔍 Verifying DMG..."
	spctl --assess --type open --context context:primary-signature --verbose "$(DMG_PATH)"
	@if [ "$(GENERATE_APPCAST)" = "1" ]; then \
		$(MAKE) appcast RELEASE_TAG="$(RELEASE_TAG)" APPCAST_PATH="$(APPCAST_PATH)" APPCAST_DOWNLOAD_URL_PREFIX="$(APPCAST_DOWNLOAD_URL_PREFIX)" APPCAST_LINK="$(APPCAST_LINK)"; \
	fi
	@echo "✅ DMG: $(DMG_PATH)"

# ── Sign ───────────────────────────────────────────────────────
sign: app
	@echo "🔏 Signing app bundle..."
	@if [ -d "$(FRAMEWORKS_DIR)" ]; then \
		find "$(FRAMEWORKS_DIR)" \( -name "*.framework" -o -name "*.dylib" \) -maxdepth 1 | while read framework; do \
			codesign --force --deep --options runtime --timestamp --sign "$(SIGNING_ID)" "$$framework"; \
			echo "  ↳ Signed $$(basename "$$framework")"; \
		done; \
	fi
	codesign --force --deep --sign "$(SIGNING_ID)" \
		--entitlements NotionBridge.entitlements \
		--options runtime \
		--timestamp \
		$(APP_BUNDLE)
	@echo "✅ Signed"

# ── Notarize ───────────────────────────────────────────────────
notarize: sign
	@echo "📤 Submitting for notarization..."
	ditto -c -k --keepParent $(APP_BUNDLE) $(BUILD_DIR)/NotionBridge.zip
	xcrun notarytool submit $(BUILD_DIR)/NotionBridge.zip \
		--keychain-profile "$(NOTARIZE_PROFILE)" \
		--wait
	xcrun stapler staple $(APP_BUNDLE)
	@echo "✅ Notarized"

# ── Verify ─────────────────────────────────────────────────────
verify:
	@echo "🔍 Verification..."
	codesign --verify --deep --verbose $(APP_BUNDLE)
	spctl --assess --verbose $(APP_BUNDLE) || echo "⚠️  spctl may require notarization"
	@echo "✅ Verified"

# ── Release (full pipeline) ────────────────────────────────────
release: clean test dmg verify
	@echo "🚀 Release complete: $(DMG_PATH)"

# ── Clean ──────────────────────────────────────────────────────
clean:
	@echo "🧹 Cleaning..."
	swift package clean
	@rm -rf $(APP_BUNDLE) $(DMG_STAGING)
	@rm -f $(BUILD_DIR)/*.zip $(BUILD_DIR)/*.dmg
	@echo "✅ Clean"
