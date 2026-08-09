TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = lsd cfprefsd
FINALPACKAGE = 1
THEOS_PACKAGE_SCHEME = roothide
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = roothidehooks

roothidehooks_FILES = $(wildcard *.x) $(wildcard *.c) $(wildcard *.m)
# 3.x merge: 直接使用 _external/include 原始私有头（含 xpc 私有头）。
# 3.x BaseBin/Makefile 会在新 SDK（iOS 17.4+，如 CI 的 Xcode 26.5）存在 xpc.modulemap 时删除 .include/xpc，
# 导致 roothidehooks 落到 SDK 的 xpc.h → xpc_connection_get_pid 标 API_UNAVAILABLE(ios) 编译失败。
# 私有头里该函数是 __OSX_AVAILABLE_STARTING(__MAC_10_7, __IPHONE_5_0)，无 unavailable 标记，可正常编译。
# jbserver.c（libjailbreak）不受影响，仍用 SDK 头的 xpc_dictionary_copy/set_mach_send 声明。
roothidehooks_CFLAGS = -Werror -fobjc-arc -I../_external/include
roothidehooks_LDFLAGS = -rpath @loader_path/.jbroot/Library/Frameworks -rpath @loader_path/fallback -L../libjailbreak -ljailbreak
roothidehooks_INSTALL_PATH = /basebin

include $(THEOS_MAKE_PATH)/tweak.mk

after-roothidehooks-all::
	install_name_tool -change @loader_path/.jbroot/usr/lib/libsubstrate.dylib @rpath/CydiaSubstrate.framework/CydiaSubstrate $(THEOS_OBJ_DIR)/roothidehooks.dylib
	ldid -S $(THEOS_OBJ_DIR)/roothidehooks.dylib
