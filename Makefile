# Makefile – Notion Bridge
# PKT-329: V1-14b Build System + Connection Setup
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
DMG_NAME       = NotionBridge-v1.0.0.dmg
DMG_STAGING    = $(BUILD_DIR)/dmg-staging
SIGNING_ID    ?= Developer ID Application: KUP Solutions LLC
NOTARIZE_PROFILE ?= notionbridge-notarize

INFO_PLIST     = Info.plist
RESOURCES_DIR  = NotionBridge/App/Resources

.PHONY: debug build test app dmg sign notarize verify release clean

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
	@echo "✅ App bundle: $(APP_BUNDLE)"

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
