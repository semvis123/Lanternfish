# Releasing

Releases are built by GitHub Actions (`.github/workflows/ci.yml`) on the `xcode-27` runner.

1. Make sure `main` is green.
2. Tag the release and push the tag:

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

3. CI lints, tests and builds `Lanternfish.app` with version `0.2.0` (from the tag) and the commit count as
   the build number, then packages `Lanternfish.dmg`, `Lanternfish.zip` and `SHA256SUMS.txt`.
4. The release job creates a **draft** GitHub release with those files and generated notes.
   Review the notes, then publish it.

Every push to `main` and every pull request also uploads the same files as a workflow artifact, for
testing a build without making a release.

## Signing

Release builds are currently signed ad-hoc and not notarized, so users have to approve the first
launch in System Settings (see the README).

To ship signed and notarized builds later:

1. Create a **Developer ID Application** certificate in the Apple Developer portal and export it
   (with its private key) as a `.p12`.
2. Create an App Store Connect API key (Users and Access › Integrations) with the Developer role.
3. Add repository secrets: the base64-encoded `.p12` and its password, plus the API key, key ID and
   issuer ID.
4. In the workflow: import the certificate into a temporary keychain, build with
   `CODESIGN_IDENTITY="Developer ID Application: …"`, sign with `--options runtime --timestamp`,
   submit with `xcrun notarytool submit --wait`, then `xcrun stapler staple` the app and the DMG.

The signature shows the name of the Apple Developer account holder.
