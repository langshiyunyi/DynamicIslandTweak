THEOS ?= /var/jb/var/mobile/theos
export LC_ALL = C
export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

SUBPROJECTS = Tweak Prefs
include $(THEOS)/makefiles/common.mk
