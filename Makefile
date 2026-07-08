TARGET = TrollCleanPro
HELPER = RootHelper

CC = clang
CFLAGS = -isysroot $(shell xcode-select -p)/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk -arch arm64 -miphoneos-version-min=15.0 -fobjc-arc

all: $(TARGET) $(HELPER)

$(TARGET): src/main.m src/DeviceInfo.m
	$(CC) $(CFLAGS) -framework Foundation -framework UIKit -framework WebKit $^ -o $@

$(HELPER): src/RootHelper.m
	$(CC) $(CFLAGS) -framework Foundation -lsqlite3 $^ -o $@

clean:
	rm -f $(TARGET) $(HELPER)