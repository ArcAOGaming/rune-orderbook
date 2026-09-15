# Security and transition status

This repository was extracted from Rune Realm commit
`e1dc6602f7603d6ca86f67ad1d30bd6fc5979630`. Its filtered history and current
tree were checked for RSA JWK markers; none were found. Wallet files,
environment overrides, and JWKs remain ignored.

`npm ci` reported inherited application-tooling findings at extraction time:
1 moderate and 1 high. This split does not claim to remediate them. Dependency
upgrades must keep the standalone build green and must not be conflated with
changes to custody or matching behavior.

The browser surface is read-only in phase one. No wallet or signing code is
accepted here until the unreleased `rune-ao` boundary is product-neutral and
its signature, slot-correlation, and ambiguous-write behavior has parity tests.
The live Lua suite remains the authority for custody and matching security.
