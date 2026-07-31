# iOSIP

iOSIP routes calls from the stock iOS 6 Phone app through SIP. It provides
outgoing and incoming calls, native call UI, audio routing, call controls,
return-to-call status bar behavior, recents integration, and missed-call
notifications.

## Supported devices

- iPhone 5 running iOS 6.1.4
- iPhone 4S running iOS 6.1.3

Other devices and iOS versions are untested.

Settings languages: English and Korean.

## Requirements

- Jailbroken iOS device with MobileSubstrate and PreferenceLoader
- Theos with an iPhoneOS 10.3 SDK
- macOS toolchain capable of building `armv7`
- PJSIP source at commit `3e7b75cb2e482baee58c1991bd2fa4fb06774e0d`

## Build

Initialize PJSIP:

```sh
git submodule update --init
cd vendor/pjproject
printf '%s\n' '#define PJ_CONFIG_IPHONE 1' \
  '#include <pj/config_site_sample.h>' > pjlib/include/pj/config_site.h
DEVPATH=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer \
IPHONESDK="$THEOS/sdks/iPhoneOS10.3.sdk" \
ARCH="-arch armv7" \
MIN_IOS="-miphoneos-version-min=6.0" \
./configure-iphone --disable-video
make dep
make
cd ../..
```

Build iOSIP:

```sh
make clean package FINALPACKAGE=1
```

Package identifier: `me.ancal.iosip`.

## Configuration

Install package, then open Settings > iOSIP. Enter SIP server, port, username,
and password, then tap the save and re-register button. `MediaHost` normally
stays empty; set it only when public SDP address differs from RTP address.

For manual configuration, copy `config/device.example.plist` to:

```text
/var/mobile/Library/Preferences/me.ancal.iosip.plist
```

Never commit a populated `config/device.plist`.

## Warning

This tweak uses private iOS APIs and replaces normal Phone app call routing
with SIP-first behavior. Do not use it for emergency calling.

## License

iOSIP is licensed under GPL-2.0-or-later. See `LICENSE`.

PJSIP in `vendor/pjproject` is also available under GPL-2.0-or-later or a
separate commercial license.
