# Contributing to VPS Manager

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an issue with your macOS version, the server's Linux distribution, what you did, and
what happened. Please remove hostnames, IPs, usernames and anything else private from logs
and screenshots before you post them.

## Making a change

1. Fork the repo and create a branch.
2. Open `VPSManager.xcodeproj` in Xcode 15 or later and run the `VPSManager` scheme
   (see the README for the Metal Toolchain note).
3. Keep changes focused, and match the style of the code around them.
4. If you add files or change targets or settings, edit `project.yml`, run `xcodegen`
   (`brew install xcodegen`), and commit both `project.yml` and the regenerated project.
5. Check that a Release build passes (CI runs the same build):

   ```bash
   xcodebuild -project VPSManager.xcodeproj -scheme VPSManager -configuration Release -destination "generic/platform=macOS" build
   ```

6. Open a pull request that says what changed and how you tested it.

## Ground rules

- The app shells out to the system `ssh`, `rsync` and `ssh-keygen`. Prefer that over
  reimplementing protocols.
- Nothing should leave the user's Mac except SSH connections to servers they added.
- Secrets belong in the Keychain, never in the JSON store or backups.
- Anything that changes a server should show the user what it will do first.

## Security issues

Please don't open a public issue for a security problem. Email hello@virusofficial.dev instead.

By contributing, you agree that your contributions are licensed under the MIT License.
