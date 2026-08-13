# macOS release signing

GitHub Releases use the fixed self-signed code-signing certificate in
`PocketIMGShot-Release.pem`. Its SHA-256 fingerprint is:

```text
21cbc4b8cd79e7623838e89db90717753fc5f7019afa74ab22d25e830c6e271b
```

The encrypted PKCS#12 bundle and its password are stored separately in the
`MACOS_SIGNING_CERTIFICATE_P12` and `MACOS_SIGNING_CERTIFICATE_PASSWORD`
GitHub Actions secrets. The private key must never be committed.

The release workflow fails if either secret is missing, if the private
identity does not match this public certificate, or if the finished app is
ad-hoc signed. Rotating this certificate changes the app's designated code
identity and can require users to grant screen-capture permission again.

This identity provides continuity for personal distribution. It is not an
Apple Developer ID certificate and cannot be used for Apple notarization.
