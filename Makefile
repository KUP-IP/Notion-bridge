# Makefile – Notion Bridge
# PKT-329: V1-14b Build System + Connection Setup
# PKT-346: V1-QUALITY-POLISH — Added install and clean-tcc targets
#
# Standard workflow: make clean → make test → make app → make dmg → make release
# Debug workflow:    make debug
# Dev app bundle:    make app (unsigned, for local testing)

APP_NAME       = Notion Bridge
BUNDLE_ID      = kup.solutions.notion-bridge
BINARY_NAME    = NotionBridge
BUILD_DIR      = .build
RELEASE_DIR    = $(BUILD_DIR)/release
DEBUG_DIR      = $(BUILD_DIR)/debug
APP_BUNDLE     = $(BUILD_DIR)/NotionBridge.app
DMG_NAME       = notion-bridge-v1.1.0.dmg
DMG_STAGING    = $(BUILD_DIR)/dmg-staging
SIGNING_ID    ?= Developer ID Application: Isaiah Peters (VP24Z9CS22)
NOTARIZE_PROFILE ?= notionbridge-notarize

INFO_PLIST     = Info.plist
RESOURCES_DIR  = NotionBridge/App/Resources

.PHONY: debug build test app dmg sign notarize verify release clean install clean-tcc

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
	@cp $(RELEASE_DIR)/$(BINARY_NAME) "$(APP_BUNDLE)/Contents/MacOS/$(BINARY_NAME)"
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
	@echo "✅ App bundle: $(APP_BUNDLE)"

# ── Install ────────────────────────────────────────────────────────────
install: app
	@echo "📲 Installing to /Applications..."
	@rm -rf "/Applications/Notion Bridge.app" "/Applications/NotionBridge.app"
	@cp -R "$(APP_BUNDLE)" "/Applications/Notion Bridge.app"
	@echo "🧹 Clearing old TCC cache..."
	-tccutil reset All solutions.kup.keepr
	@echo "🔄 Refreshing icon caches..."
	@killall Dock 2>/dev/null || true
	@echo "✅ Installed: /Applications/Notion Bridge.app"

# ── Clean TCC ──────────────────────────────────────────────────────────
clean-tcc:
	@echo "🧹 Resetting TCC for old bundle ID..."
	-tccutil reset All solutions.kup.keepr
	@echo "🧹 Resetting TCC for current bundle ID..."
	-tccutil reset All kup.solutions.notion-bridge
	@echo "✅ TCC reset complete — permissions will be re-requested on next launch"

# ── DMG (disk image) ──────────────────────────────────────────
dmg: app
	@echo "💿 Creating disk image..."
	@rm -rf $(DMG_STAGING)
	@mkdir -p $(DMG_STAGING)
	@cp -R $(APP_BUNDLE) $(DMG_STAGING)/
	@test -f README.md && cp README.md $(DMG_STAGING)/ || true
	hdiutil create -volname "$(APP_NAME)" \
		-srcfolder $(DMG_STAGING) \
		-ov -format UDZO \
		$(BUILD_DIR)/$(DMG_NAME)
	@rm -rf $(DMG_STAGING)
	@echo "✅ DMG: $(BUILD_DIR)/$(DMG_NAME)"

# ── Sign ───────────────────────────────────────────────────────
sign: app
	@echo "🔏 Signing app bundle..."
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
release: clean test app sign notarize dmg verify
	@echo "🚀 Release complete: $(BUILD_DIR)/$(DMG_NAME)"

# ── Clean ──────────────────────────────────────────────────────
clean:
	@echo "🧹 Cleaning..."
	swift package clean
	@rm -rf $(APP_BUNDLE) $(DMG_STAGING)
	@rm -f $(BUILD_DIR)/*.zip $(BUILD_DIR)/*.dmg
	@echo "✅ Clean"
