TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = lsd cfprefsd
FINALPACKAGE = 1
THEOS_PACKAGE_SCHEME = roothide
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = roothidehooks

roothidehooks_FILES = $(wildcard *.x) $(wildcard *.c) $(wildcard *.m)
# 3.x merge: xpc_connection_get_pid 等 macOS-only API 在 iOS 上符号真实存在但头文件标 unavailable，
# rh2 用"删 Xcode SDK xpc 头"解决，但那会破坏 3.x jbserver.c 需要的 xpc_dictionary_copy/set_mach_send 声明。
# 这里改用忽略 unavailable 声明警告，源码零改动。
roothidehooks_CFLAGS = -Werror -fobjc-arc -I../.include -Wno-unavailable-declarations
roothidehooks_LDFLAGS = -rpath @loader_path/.jbroot/Library/Frameworks -rpath @loader_path/fallback -L../libjailbreak -ljailbreak
roothidehooks_INSTALL_PATH = /basebin

include $(THEOS_MAKE_PATH)/tweak.mk

after-roothidehooks-all::
	install_name_tool -change @loader_path/.jbroot/usr/lib/libsubstrate.dylib @rpath/CydiaSubstrate.framework/CydiaSubstrate $(THEOS_OBJ_DIR)/roothidehooks.dylib
	ldid -S $(THEOS_OBJ_DIR)/roothidehooks.dylib
