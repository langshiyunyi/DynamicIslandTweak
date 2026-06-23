THEOS ?= /var/jb/var/mobile/theos
export LC_ALL = C
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DynamicIslandTweak
DynamicIslandTweak_FILES = Tweak.x DIContentView.m DIWindow.m DIDisplayManager.m DILocalization.m
DynamicIslandTweak_CFLAGS = -fobjc-arc
DynamicIslandTweak_FRAMEWORKS = UIKit CoreGraphics QuartzCore

LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS_MAKE_PATH)/tweak.mk
