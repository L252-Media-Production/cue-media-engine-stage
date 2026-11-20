# SDK setup

The Blackmagic and NDI SDKs are used for **building only**. They are not committed (their licences
do not allow redistributing the SDK itself). End users do not need either SDK.

## What end users need
- **Blackmagic Desktop Video** (the free driver) for DeckLink cards. It provides the DeckLink API at runtime.
- **NDI runtime**, unless we bundle the NDI library under NDI's licence terms (to be decided).

Before shipping to other people, read both SDK licences to confirm what may be included in a distributed app.

## What developers need locally
1. Install Xcode (current version) and XcodeGen: `brew install xcodegen`.
2. Install Blackmagic Desktop Video and reboot, then check the card appears in Blackmagic Desktop Video Setup.
3. Download the **Blackmagic DeckLink SDK** (free, needs a Blackmagic developer sign-in) and copy its
   Mac `include` folder to `vendor/DeckLinkSDK/include`.
4. Download the **NDI SDK** (free) and copy its `include` and `lib` folders to `vendor/NDISDK/`.

The `vendor/` folder is git-ignored apart from its README.

## Thunderbolt chassis
DeckLink Duo 2 cards are PCIe. On these Macs they sit in a Sonnet Echo III Thunderbolt chassis.
Connect the chassis directly to the Mac and confirm the cards are listed before testing.
