# This file is part of MXE.
# See index.html for further information.

PKG             := libcutl
$(PKG)_IGNORE   :=
$(PKG)_VERSION  := 1.10.0
$(PKG)_SHORTV   := 1.10
$(PKG)_CHECKSUM := 125163c670e372b47d5626d54379ff8fbaded6ccd5db77ac0bf5912a4017121c
$(PKG)_SUBDIR   := $(PKG)-$($(PKG)_VERSION)
$(PKG)_FILE     := $(PKG)-$($(PKG)_VERSION).tar.bz2
$(PKG)_URL      := http://www.codesynthesis.com/download/libcutl/$($(PKG)_SHORTV)/$($(PKG)_FILE)
$(PKG)_DEPS     :=
$(PKG)_TARGETS  := $(BUILD)

define $(PKG)_BUILD
    cd '$(1)' && ./configure \
        $(MXE_CONFIGURE_OPTS) \
        --disable-debug  \
    --disable-static \
    --enable-shared
    $(MAKE) -C '$(1)' -j '$(JOBS)' install
endef
