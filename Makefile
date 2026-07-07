TARGET = QiLong-Dynamic-Whitelist
HELPER = RootHelper
CC = clang
SYSROOT = $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk")
CFLAGS = -isysroot $(SYSROOT) -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc

all: $(TARGET) $(HELPER)

$(TARGET): src/main.m src/DeviceInfo.m
	$(CC) $(CFLAGS) -framework Foundation -framework UIKit -framework WebKit $^ -o $@

$(HELPER): src/RootHelper.m
	$(CC) $(CFLAGS) -framework Foundation -lsqlite3 $^ -o $@

clean:
	rm -f $(TARGET) $(HELPER) QiLong-Dynamic-Whitelist.ipa
	rm -rf Payload QiLong-Dynamic-Whitelist.app
