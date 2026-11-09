TARGET := iphone:clang:latest:15.0
ARCHS = arm64

INSTALL_TARGET_PROCESSES = Telegram
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LinkiGhost
LinkiGhost_FILES = Tweak.x
LinkiGhost_CFLAGS = -fobjc-arc
LinkiGhost_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
