# Design QA

**Comparison Target**

- Source visual truth:
  - `/var/folders/_x/j99_pl_n56dgsr_ws034gfg80000gn/T/codex-clipboard-ad4c46af-0c27-47e1-9209-1d7175d88767.png`
  - `/var/folders/_x/j99_pl_n56dgsr_ws034gfg80000gn/T/codex-clipboard-4cae624a-3904-4a3f-9c96-ab8101107536.png`
- Rendered implementation:
  - `docs/design-qa/home-final.png`
  - `docs/design-qa/device-tab-final.png`
  - `docs/design-qa/project-final.png`
  - `docs/design-qa/detail-final.png`
  - `docs/design-qa/new-dialog.png`
- Full-view comparison: `docs/design-qa/home-comparison.png`
- Focused detail comparison: `docs/design-qa/detail-comparison.png`
- Focused device-tab comparison: `docs/design-qa/device-tab-comparison.png`
- State: Android emulator connected to the `wangxin` macOS device with Claude selected; home, project conversation list, conversation detail, and new-conversation dialog were exercised.

**Viewport and Normalization**

- Source pixels: `700 x 1452` (home) and `700 x 538` (detail crop). The source screenshots are annotated captures, so their logical viewport and density are not available.
- Implementation pixels: `1080 x 2400`, Android logical viewport `360 x 800`, device pixel ratio `3`.
- The home comparison preserves each screenshot's aspect ratio inside equal `1080 x 2400` panels. The detail comparison uses the source detail crop and the matching top `1080 x 650` implementation region. Red arrows and touch indicators in the source are treated as reviewer annotations, not product UI.

**Findings**

- No actionable P0, P1, or P2 differences remain for the four requested changes.
- [P3] The implementation gives “新建” a filled primary treatment while the annotated source only sketches the intended control boundary. This is an intentional hierarchy choice: creating a conversation is the primary action and search remains the wider secondary action.

**Required Fidelity Surfaces**

- Fonts and typography: both captures use the Android system typography; title, section-heading, body, and control weights remain consistent with the existing app hierarchy. No clipping or unintended wrapping was observed.
- Spacing and layout rhythm: the device selector is visibly shorter, section spacing remains intact, and the persistent bottom action bar does not cover list content. Project and detail screens retain safe-area spacing.
- Colors and visual tokens: existing Material theme colors and selected-provider teal are reused. Disabled/active affordances and contrast remain legible.
- Image quality and asset fidelity: no raster artwork is required. Provider and operating-system identities use Material vector icons at native density, including the Apple and Windows platform marks; no placeholder or handcrafted asset substitutes were introduced.
- Copy and content: “搜索”, “新建”, provider name, permission level, project name, and conversation metadata match the requested semantics. The project search is scoped to the current workspace.

**Interaction Evidence**

- Home search and new controls are visible and enabled for the selected provider.
- New opens a provider-specific dialog with optional title and workspace fields.
- Project navigation exposes the same search/new controls; new is pre-scoped to the project workspace.
- Conversation detail shows the provider icon in the title and starts with metadata collapsed; tapping the metadata row expands it.

**Comparison History**

- Initial pass: `[P2]` search was visibly disabled for a provider without `conversation.search`, which weakened the requested persistent entry and prevented the existing unsupported-capability explanation from being reached. Evidence: `docs/design-qa/home-initial-disabled-search.png`.
- Fix: enabled the search entry whenever a provider is selected and kept capability handling inside the search screen.
- Post-fix evidence: `docs/design-qa/home-final.png`, `docs/design-qa/project-final.png`, and `docs/design-qa/home-comparison.png` show active search controls in both requested locations.
- Follow-up pass: `[P2]` the macOS device still used the generic `laptop_mac` symbol and the `ChoiceChip` treatment left the device selector visually heavy and indistinct.
- Fix: replaced the chip with a compact, bordered device tab; mapped macOS to the Apple mark and Windows to the Windows mark; added a platform-icon tile and a semantic connection-state dot.
- Post-fix evidence: `docs/design-qa/device-tab-final.png` and `docs/design-qa/device-tab-comparison.png` show the recognizable platform identity, clearer selected state, and improved information hierarchy.

**Open Questions**

- None blocking. The exact source density was unavailable because the supplied screenshots are annotated crops; comparisons therefore focus on the marked regions and interaction state rather than false pixel-level precision.

**Implementation Checklist**

- [x] Provider icon in conversation detail title.
- [x] Conversation metadata collapsed by default and expandable.
- [x] Shorter device selector with operating-system-specific icon.
- [x] Bottom search/new actions on home and project screens.
- [x] Functional `conversation.create` path through the generated Gateway SDK.
- [x] Full Flutter test suite, Android build, overwrite install, and emulator interaction check.

**Follow-up Polish**

- P3 only: provider-branded custom icon assets could replace Material symbols later if the handshake protocol begins supplying renderable asset references rather than symbolic icon names.

final result: passed
