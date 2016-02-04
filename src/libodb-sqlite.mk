# This file is part of MXE.
# See index.html for further information.

PKG             := libodb-sqlite
$(PKG)_IGNORE   :=
$(PKG)_VERSION  := 2.4.0
$(PKG)_SHORTV   := 2.4
$(PKG)_CHECKSUM := 149bc356cbe81d06ff27434c984bb745af06d745243bdc830e6cbb37e03009ed
$(PKG)_SUBDIR   := $(PKG)-$($(PKG)_VERSION)
$(PKG)_FILE     := $(PKG)-$($(PKG)_VERSION).tar.bz2
$(PKG)_URL      := http://www.codesynthesis.com/download/odb/$($(PKG)_SHORTV)/$($(PKG)_FILE)
$(PKG)_DEPS     := gcc libodb sqlite

define $(PKG)_BUILD
    cd '$(1)' && ./configure \
        $(MXE_CONFIGURE_OPTS)
    $(MAKE) -C '$(1)' -j '$(JOBS)' install
endef
