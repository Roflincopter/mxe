# This file is part of MXE.
# See index.html for further information.

PKG             := odb
$(PKG)_IGNORE   :=
$(PKG)_VERSION  := 2.4.0
$(PKG)_SHORTV   := 2.4
$(PKG)_CHECKSUM := 6785154fa98ea3977c8c2ab38cec16c4aa78c2c2039e80cd2908347b1c1d4198
$(PKG)_SUBDIR   := $(PKG)-$($(PKG)_VERSION)
$(PKG)_FILE     := $(PKG)-$($(PKG)_VERSION).tar.bz2
$(PKG)_URL      := http://www.codesynthesis.com/download/odb/$($(PKG)_SHORTV)/$($(PKG)_FILE)
$(PKG)_DEPS     := libcutl
$(PKG)_TARGETS  := $(BUILD)

define $(PKG)_BUILD
    echo $(MXE_CONFIGURE_OPTS)
    echo $(PREFIX)
    echo $(CPPFLAGS)
    cd '$(1)' && CPPFLAGS="-I$(SHELL $(BUILD_CXX) --print-file-name=plugin)/include -I$(PREFIX)/$(BUILD)/include" LDFLAGS="-L$(PREFIX)/$(BUILD)/lib" ./configure \
        $(MXE_CONFIGURE_OPTS) \
        --disable-debug \
        --disable-static \
        --enable-shared
    $(MAKE) -C '$(1)' -j '$(JOBS)' install
endef
