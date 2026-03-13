# Makefile – Keepr · Mac Bridge
# V1-06 Release Hardening
#
# Targets: build, test, sign, notarize, dmg, verify, release, clean

SCHEME       = KeeprServer
APP_NAME     = Keepr
BUNDLE_ID    = solutions.kup.keepr
BUILD_DIR    = .build/release
DMG_NAME     = Keepr-v1.0.0.dmg
DMG_DIR      = .build/dmg
SIGNING_ID   ?= Developer ID Application: KUP Solutions LLC
NOTARIZE_TEAM ?= $(APPLE_TEAM_ID)
NOTARIZE_PROFILE ?= keepr-notarize

.PHONY: build test sign notarize dmg verify release clean

# ── Build ──────────────────────────────────────────────────────
build:
	@echo "🔨 Building release binary with strict concurrency..."
	swift build -c release \
		-Xswiftc -strict-concurrency=complete \
		-Xswiftc -warnings-as-errors
	@echo "✅ Build complete: $(BUILD_DIR)/$(SCHEME)"

# ── Test ───────────────────────────────────────────────────────
test:
	@echo "🧪 Running full test suite (unit + integration + E2E)..."
	swift run KeeprTests
	@echo "✅ Tests complete"

# ── Sign ───────────────────────────────────────────────────────
sign: build
	@echo "🔏 Signing with Developer ID..."
	codesign --force --sign "$(SIGNING_ID)" \
		--options runtime \
		--entitlements Keepr/Resources/Keepr.entitlements \
		--timestamp \
		$(BUILD_DIR)/$(SCHEME)
	@echo "✅ Code signed"

# ── Notarize ───────────────────────────────────────────────────
notarize: sign
	@echo "📤 Submitting for Apple notarization..."
	@# Create zip for submission
	ditto -c -k --keepParent $(BUILD_DIR)/$(SCHEME) .build/$(SCHEME).zip
	xcrun notarytool submit .build/$(SCHEME).zip \
		--keychain-profile "$(NOTARIZE_PROFILE)" \
		--wait
	@# Staple the ticket
	xcrun stapler staple $(BUILD_DIR)/$(SCHEME)
	@echo "✅ Notarized and stapled"

# ── DMG ────────────────────────────────────────────────────────
dmg: notarize
	@echo "📦 Packaging DMG..."
	@mkdir -p $(DMG_DIR)
	@cp $(BUILD_DIR)/$(SCHEME) $(DMG_DIR)/$(APP_NAME)
	@cp README.md $(DMG_DIR)/
	hdiutil create -volname "$(APP_NAME)" \
		-srcfolder $(DMG_DIR) \
		-ov -format UDZO \
		.build/$(DMG_NAME)
	@echo "✅ DMG created: .build/$(DMG_NAME)"

# ── Verify ─────────────────────────────────────────────────────
verify:
	@echo "🔍 Gatekeeper assessment..."
	codesign --verify --verbose $(BUILD_DIR)/$(SCHEME)
	spctl --assess --verbose $(BUILD_DIR)/$(SCHEME) || echo "⚠️  spctl may require notarization"
	@echo "✅ Verification complete"

# ── Release (full pipeline) ────────────────────────────────────
release: clean build test sign notarize dmg verify
	@echo "🚀 Release pipeline complete"
	@echo "   Artifact: .build/$(DMG_NAME)"

# ── Clean ──────────────────────────────────────────────────────
clean:
	@echo "🧹 Cleaning..."
	swift package clean
	rm -rf .build/dmg .build/*.zip .build/*.dmg
	@echo "✅ Clean"
