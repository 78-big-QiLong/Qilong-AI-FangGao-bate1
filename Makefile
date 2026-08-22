TARGET = QiLong-Dynamic-Whitelist
HELPER = RootHelper
CC = clang
SYSROOT = $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk")
# 🛡️ 高规格安全加固编译参数：隐藏符号可见性、死代码剥离、栈保护、ARC防御
CFLAGS = -isysroot $(SYSROOT) -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc \
         -O2 -fvisibility=hidden -fvisibility-inlines-hidden -fstack-protector-strong \
         -Wl,-dead_strip -Wl,-exported_symbol,_main

all: $(TARGET) $(HELPER)

$(TARGET): src/main.m src/DeviceInfo.m
	$(CC) $(CFLAGS) -framework Foundation -framework UIKit -framework WebKit -framework CoreLocation $^ -o $@

$(HELPER): src/RootHelper.m
	$(CC) $(CFLAGS) -framework Foundation -framework Security -lsqlite3 $^ -o $@

clean:
	rm -f $(TARGET) $(HELPER) *.ipa *.tipa *.deb
	rm -rf Payload QiLong-Dynamic-Whitelist.app build_deb