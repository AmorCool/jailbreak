CC = clang

CFLAGS = -I../.include -isysroot $(shell xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=15.0 -Wno-deprecated-declarations -fno-stack-check -D_FORTIFY_SOURCE=0 -O2
LDFLAGS = -shared -Xlinker -add_split_seg_info
FILES = $(wildcard src/*.c src/*.S ../libjailbreak/src/jbclient_mach.c)
# roothide merge (build38.15): iOS18+ merge 排除 roothider.c/S。
# 真机证据：roothider 的 dyld4 Loader::expandAtLoaderPath hook（@loader_path/.jbroot
# 机制，rh2 移植）在 iOS 18 dyld 上不兼容，merge 进 patched dyld 后 dyld 启动
# 早期崩溃（panic 084910/094144 等，dyld UUID=DOPA-3.0.4，崩溃在 merge 代码区）。
# 官方 3.0.4 dyldhook 无 roothider；iOS 18 上 roothide 的动态加载不依赖该 hook。
# iOS15/16-17 仍包含（rh2 机制需要）。
FILES_IOS15 = $(wildcard src/generated/ios15/*.c)
FILES_IOS16-17 = $(wildcard src/generated/ios16-17/*.c)
FILES_IOS18+ = $(wildcard src/generated/ios18+/*.c)
FILES_NO_ROOTHIDER = $(filter-out src/roothider.c src/roothider.S,$(FILES))

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

dyldhook_merge.arm64e.iOS18+.dylib: $(FILES_NO_ROOTHIDER) $(FILES_IOS18+)
	$(CC) -arch arm64e $(CFLAGS) -DIOS=18 $(LDFLAGS) -o $@ $^
	@ldid -Cadhoc -S $@
	$(call CHECK_SELF_CONTAINED,$@)

dyldhook_merge.arm64.iOS18+.dylib: $(FILES_NO_ROOTHIDER) $(FILES_IOS18+)
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