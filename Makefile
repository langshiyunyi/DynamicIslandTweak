THEOS ?= /var/jb/var/mobile/theos
export LC_ALL = C
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export THEOS_PACKAGE_SCHEME = rootless

SUBPROJECTS = Tweak Prefs
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
