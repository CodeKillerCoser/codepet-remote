# Design QA

**Comparison Target**

- Source visual truth: `docs/design-qa/pair-device-reference.png`.
- Rendered implementation: live Android emulator captures of the automatic-discovery screen and the manual-add bottom sheet on 2026-09-03.
- State: Android emulator pairing screen with one paired Host in `failed` connection state and no unpaired Host currently discovered.
- Full-view comparison: both images were opened together in one visual comparison input. The red marks in the source are reviewer annotations, not product UI.

**Viewport and Normalization**

- Source pixels: `706 x 1658`, including the Android Emulator window title and annotated device capture.
- Implementation pixels: `1080 x 2400` at Android physical density `420 dpi`, approximately `411 x 914` logical dp.
- The current captures use the same tall Android device aspect ratio. Comparison was normalized by app-owned content regions; emulator window chrome was excluded from fidelity judgments.

**Findings**

- No actionable P0, P1, or P2 differences remain for the requested adjustment.
- The new connected-device section contains the requested `名称 / 系统 / 在线状态` columns and reports the live session state.
- The discovered-device section is visually separated below it, includes a standard Material refresh control, and provides a legible empty state.
- Already paired Hosts are excluded from the discovered-device list, preventing duplicate actions across the two regions.
- The default screen no longer creates or renders a camera surface. A single manual-add entry opens scan, paste-QR, and passcode choices.

**Required Fidelity Surfaces**

- Fonts and typography: existing Android system typography and Material hierarchy are preserved; headings, table labels, row values, and status text are readable without clipping.
- Spacing and layout rhythm: both requested regions fit in the initial viewport, with one compact table, a divider, a right-aligned refresh action, and a full-width manual-add action.
- Colors and visual tokens: the existing seeded Material color scheme is reused. Online, connecting, offline, and failed states use semantic colors with text labels rather than color alone.
- Image quality and asset fidelity: the QR scanner is a separate live platform camera surface created only after the scan action is selected. No new raster artwork was required; the refresh, computer, radar, link, and status symbols use Material icons.
- Copy and content: the labels match the annotated request, with explicit automatic-discovery guidance, empty-state guidance, and three manual pairing choices.

**Interaction Evidence**

- The refresh control clears cached candidates and interrupts the active mDNS scan so a new scan begins immediately.
- Widget tests verify connected-device columns, current state, paired/discovered partitioning, refresh activation, the empty state, lazy scanner creation, the manual method sheet, and the Host-bound passcode entry.
- A discovery test verifies that refresh clears cached Hosts and starts a second scan.
- The full Flutter suite passes with `199` tests; `flutter analyze` reports no issues.
- The debug APK builds and installs successfully on `emulator-5554`; the automatic-discovery screen and manual-add sheet were inspected at `1080 x 2400` with no overflow.

**Comparison History**

- Initial comparison: the implemented screen placed both annotated regions in the requested location.
- Manual-entry revision: the always-open scanner and inline diagnostics were removed from the default screen. Emulator review confirmed that all three manual actions remain visible in the bottom sheet without clipping.

**Open Questions**

- None blocking. The source annotation did not specify row actions, so connected-device rows remain informational on this screen.

**Implementation Checklist**

- [x] Show connected devices with name, system, and live online status.
- [x] Present automatic discovery without opening the camera.
- [x] Exclude already paired Hosts from discovery results.
- [x] Add a functional refresh button and an empty state.
- [x] Add scan, paste-QR, and Host-bound 6-digit passcode paths behind one manual entry.
- [x] Verify on the Android emulator and retain the installed build for review.

**Follow-up Polish**

- No P3 follow-up is required for the annotated scope.

final result: passed
