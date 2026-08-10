CC = clang

CFLAGS = -I../.include -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=15.0 -Wno-deprecated-declarations -fno-stack-check -D_FORTIFY_SOURCE=0 -O2
LDFLAGS = -shared -Xlinker -add_split_seg_info
FILES = $(wildcard src/*.c src/*.S ../libjailbreak/src/jbclient_mach.c)
# roothide merge (build38.21 纠错：iOS18 恢复包含 roothider.c/S)。
# roothider 的 dyld4 Loader::expandAtLoaderPath hook（把 @loader_path/.jbroot 重写为
# 真 jbroot）是 roothide 加载库的**核心机制**，所有 roothide app 都靠它加载
# libroothide.dylib。build38.15 曾把它从 iOS18 合并排除（误判为硬重启元凶），但
# build38.20 已证明真凶是 launchdhook/systemhook 初始化里的 getenv/dladdr dyld API
# 调用 + jailbreakd 注入弯路（均已修），硬重启消失。真机证据（build38.20 Sileo
# 崩溃 1786353731）：Library not loaded: @loader_path/.jbroot/usr/lib/libroothide.dylib
# → .jbroot 未被重写（因 iOS18 patched dyld 缺此 hook）。hook 代码本身安全
# （jbinfo_get_jbroot()==NULL 时透传、不崩）。故 iOS18 恢复与 iOS15/16-17 一致包含。
FILES_IOS15 = $(wildcard src/generated/ios15/*.c)
FILES_IOS16-17 = $(wildcard src/generated/ios16-17/*.c)
FILES_IOS18+ = $(wildcard src/generated/ios18+/*.c)

all: dyldhook_merge.arm64e.iOS15.dylib dyldhook_merge.arm64.iOS15.dylib dyldhook_merge.arm64e.iOS16-17.dylib dyldhook_merge.arm64.iOS16-17.dylib dyldhook_merge.arm64e.iOS18+.dylib dyldhook_merge.arm64.iOS18+.dylib

define CHECK_SELF_CONTAINED
	@UNDEF=$$(nm -u $(1) 2>/dev/null); \
	if [ -n "$$UNDEF" ]; then \
		echo "FAIL: $(1) has external symbols:"; \
		echo "$$UNDEF"; \
		exit 1; \
	fi
	@echo "PASS: $(1) is self-contained"
endef

dyldhook_merge.arm64e.iOS18+.dylib: $(FILES) $(FILES_IOS18+)
	$(CC) -arch arm64e $(CFLAGS) -DIOS=18 $(LDFLAGS) -o $@ $^
	@ldid -Cadhoc -S $@
	$(call CHECK_SELF_CONTAINED,$@)

dyldhook_merge.arm64.iOS18+.dylib: $(FILES) $(FILES_IOS18+)
	$(CC) -arch arm64 $(CFLAGS) -DIOS=18 $(LDFLAGS) -o $@ $^
	@ldid -Cadhoc -S $@
	$(call CHECK_SELF_CONTAINED,$@)

dyldhook_merge.arm64e.iOS16-17.dylib: $(FILES) $(FILES_IOS16-17)
	$(CC) -arch arm64e $(CFLAGS) -DIOS=16 $(LDFLAGS) -o $@ $^
	@ldid -Cadhoc -S $@
	$(call CHECK_SELF_CONTAINED,$@)

dyldhook_merge.arm64.iOS16-17.dylib: $(FILES) $(FILES_IOS16-17)
	$(CC) -arch arm64 $(CFLAGS) -DIOS=16 $(LDFLAGS) -o $@ $^
	@ldid -Cadhoc -S $@
	$(call CHECK_SELF_CONTAINED,$@)

dyldhook_merge.arm64e.iOS15.dylib: $(FILES) $(FILES_IOS15)
	$(CC) -arch arm64e $(CFLAGS) -DIOS=15 $(LDFLAGS) -o $@ $^
	@ldid -Cadhoc -S $@
	$(call CHECK_SELF_CONTAINED,$@)

dyldhook_merge.arm64.iOS15.dylib: $(FILES) $(FILES_IOS15)
	$(CC) -arch arm64 $(CFLAGS) -DIOS=15 $(LDFLAGS) -o $@ $^
	@ldid -Cadhoc -S $@
	$(call CHECK_SELF_CONTAINED,$@)

clean:
	@rm -f dyldhook_merge.arm64e.iOS18+.dylib
	@rm -f dyldhook_merge.arm64.iOS18+.dylib
	@rm -f dyldhook_merge.arm64e.iOS16-17.dylib
	@rm -f dyldhook_merge.arm64.iOS16-17.dylib
	@rm -f dyldhook_merge.arm64e.iOS15.dylib
	@rm -f dyldhook_merge.arm64.iOS15.dylib