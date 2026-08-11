TARGET = forkfix.dylib
CC = clang

# build38.41: 双架构（arm64 + arm64e）+ 去掉对 systemhook.dylib 的链接依赖。
# 原 LDFLAGS = ../systemhook/systemhook.dylib -dynamiclib 会让 forkfix.dylib 的
# LC_LOAD_DYLIB 指向 @loader_path/systemhook.dylib，而 launchdhook roothider.m postinit
# 会把 systemhook.dylib 改名为 systemhook-<jbrand>.dylib → dlopen forkfix 时找不到
# 依赖 → 加载失败 → fork 崩溃（apt-get/mount/Reveil 全部 CODESIGNING Invalid Page）。
# 改为 -undefined dynamic_lookup：符号（litehook_hook_function 等）在运行时从
# 已加载的 systemhook 镜像中解析，不再产生文件名依赖。
CFLAGS = -I../.include -I./src -I../_external/modules/litehook/src -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -arch arm64 -arch arm64e -Wno-deprecated-declarations -miphoneos-version-min=15.0 -D BUILD_STANDALONE=$(BUILD_STANDALONE) -O2
LDFLAGS = -dynamiclib -undefined dynamic_lookup

sign: $(TARGET)
	@ldid -Cadhoc -S $^

$(TARGET): $(wildcard src/*.c src/*.S ../libjailbreak/src/jbclient_*.c)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

clean:
	@rm -f $(TARGET)
