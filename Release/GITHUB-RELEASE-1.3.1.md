# AirTranslate 1.3.1

Hotfix release for Apple basic-mode auto-detect stability.

AirTranslate is an independent open-source project and is not affiliated with Apple or OpenAI.

## Changed

- Apple basic-mode source-language auto-detection is temporarily disabled while mid-session language switching is improved.
- The auto-detect toggle now stays off and shows an in-app notice explaining that the feature will be improved in a future update.
- Release metadata, ZIP, and DMG assets are updated for version `1.3.1` build `131`.

## Fixed

- Saved auto-detect preferences no longer re-enable the feature in the current build.
- Users no longer get a silent disabled toggle with no feedback.

## Download

- For most users: Download `AirTranslate.dmg`, open it, and drag `AirTranslate.app` to Applications.
- For ZIP users: Download `AirTranslate-1.3.1.zip`.
- Versioned DMG assets are also attached as `AirTranslate-1.3.1.dmg` and `AirTranslate-1.3.1.dmg.sha256`.

## Distribution Notes

AirTranslate remains fully open-source under the Apache-2.0 License.
The DMG is provided as a convenient macOS installer and does not replace source distribution.

Because this build is not Apple-notarized yet, macOS may show an "unidentified developer" warning on first launch.

If that happens:

Control-click / right-click `AirTranslate.app` -> Open -> Open

You can verify checksum using `AirTranslate.dmg.sha256`.

Older GitHub Releases remain available for users who need a previous version.
