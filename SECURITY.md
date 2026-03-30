# Security policy — NotionBridge

## Supported versions

Security fixes are applied to the **latest release** on [GitHub Releases](https://github.com/KUP-IP/Notion-bridge/releases). Use Sparkle (in-app updates) or download the current DMG from the product page.

## Reporting a vulnerability

Email **isaiah@kup.solutions** with subject line `NotionBridge security` and include:

- Description and impact
- Affected version(s) and platform (macOS / Apple Silicon)
- Steps to reproduce (proof-of-concept if possible)
- Whether you need coordinated disclosure

We aim to acknowledge within **5 business days** and to ship fixes as patch releases when practical.

**Please do not** file public GitHub issues for undisclosed vulnerabilities.

## Scope (in scope)

- Remote code execution, privilege escalation, or sandbox escape **via the NotionBridge app or its MCP surface** when used as documented
- Sparkle update integrity (signature verification bypass), if applicable to our distribution
- Issues in bundled first-party code under our control

## Out of scope

- **Physical access** or unlocked user session — NotionBridge assumes a trusted local user
- **Malicious MCP clients** with full access to localhost — the server is intended for local agents; use firewall / tunnel controls for remote exposure
- **Third-party services** (Notion API, Stripe, Cloudflare) — report to those vendors per their programs
- **Social engineering**, spam, or support abuse
- **License / entitlement** bypass — commercial enforcement is separate from security response; see README (license server is not a current product surface)

## Auto-updates

Updates are delivered via **Sparkle** with EdDSA signatures (`SUPublicEDKey` in the app). Only install NotionBridge from **official** channels listed on [kup.solutions](https://kup.solutions/notion-bridge) or this repository’s releases.

## License enforcement (not security response)

Online license validation is **not** implemented in the app today. Piracy and unauthorized redistribution are handled under **Terms of Service** and applicable law, not through this disclosure channel.
