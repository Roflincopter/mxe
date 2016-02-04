# This file is part of MXE.
# See index.html for further information.

PKG             := libodb
$(PKG)_IGNORE   :=
$(PKG)_VERSION  := 2.4.0
$(PKG)_SHORTV   := 2.4
$(PKG)_CHECKSUM := 66a1bb4e8bb6ef60cc79334f8028c4d4de98d87f2ff6f8123b4cfb7751ce0007
$(PKG)_SUBDIR   := $(PKG)-$($(PKG)_VERSION)
$(PKG)_FILE     := $(PKG)-$($(PKG)_VERSION).tar.bz2
$(PKG)_URL      := http://www.codesynthesis.com/download/odb/$($(PKG)_SHORTV)/$($(PKG)_FILE)
$(PKG)_DEPS     := gcc

define $(PKG)_BUILD
    cd '$(1)' && ./configure \
        $(MXE_CONFIGURE_OPTS)
    $(MAKE) -C '$(1)' -j '$(JOBS)' install
endef
