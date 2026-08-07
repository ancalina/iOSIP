ARCHS = armv7 arm64
TARGET = iphone:clang:10.3:6.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = iosipd iosipctl
iosipd_FILES = daemon/main.m
iosipd_CFLAGS = -fobjc-arc -Wno-deprecated-module-dot-map \
	-Wno-deprecated-declarations \
	-DPJ_AUTOCONF=1 \
	-Ivendor/pjproject/pjlib/include \
	-Ivendor/pjproject/pjlib-util/include \
	-Ivendor/pjproject/pjnath/include \
	-Ivendor/pjproject/pjmedia/include \
	-Ivendor/pjproject/pjsip/include
iosipd_LDFLAGS = -Wl,-all_load \
	$(shell find vendor/pjproject \
		-path '*/lib/*-$(THEOS_CURRENT_ARCH)-apple-darwin_ios.a' \
		! -name 'libpjsdp-*' -print) \
	-Wl,-undefined,dynamic_lookup
iosipd_FRAMEWORKS = Foundation AudioToolbox AVFoundation CoreAudio CoreFoundation UIKit
iosipd_INSTALL_PATH = /usr/libexec

iosipctl_FILES = tools/iosipctl.c
iosipctl_INSTALL_PATH = /usr/bin

TWEAK_NAME = IOSIP
IOSIP_FILES = tweak/Tweak.x tweak/SIPIPC.m
IOSIP_FRAMEWORKS = Foundation UIKit CoreTelephony
IOSIP_CFLAGS = -fobjc-arc -Wno-deprecated-module-dot-map
IOSIP_LDFLAGS = -Wl,-undefined,dynamic_lookup

BUNDLE_NAME = IOSIPPrefs
IOSIPPrefs_FILES = prefs/IOSIPRootListController.m tweak/SIPIPC.m
IOSIPPrefs_FRAMEWORKS = Foundation UIKit
IOSIPPrefs_INSTALL_PATH = /Library/PreferenceBundles
IOSIPPrefs_RESOURCE_DIRS = prefs/Resources
IOSIPPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-module-dot-map
IOSIPPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "launchctl unload /Library/LaunchDaemons/me.ancal.iosipd.plist 2>/dev/null || true"
	install.exec "launchctl load /Library/LaunchDaemons/me.ancal.iosipd.plist"
	install.exec "killall MobilePhone 2>/dev/null || true"
