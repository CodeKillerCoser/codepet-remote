# Fixed debug signing identity

`codepet-debug.keystore` is intentionally checked in at the user's request.
All local and CI Debug APKs use this same key. Do not regenerate it during
builds or on another machine; changing it prevents replacement of existing
Debug installations with the same applicationId.

- Format: PKCS12, RSA 2048, created 2026-09-09, validity 10000 days.
- Alias: `androiddebugkey`.
- Store/key password: `android` (public debug configuration).
- Certificate SHA-256:
  `15:D8:C1:3A:B1:AE:0A:EF:A0:01:0C:7A:90:D7:F2:EE:D2:88:3B:E2:F1:BE:9E:C3:99:BE:B7:55:5D:53:78:60`.

This is a public development identity. Release uses the separately configured
`CODEPET_RELEASE_*` identity and fails if it is absent. Never put a production
keystore or password here. The ignore exception permits only this exact file.
