# This file is part of MXE.
# See index.html for further information.

PKG             := libodb-pgsql
$(PKG)_IGNORE   :=
$(PKG)_VERSION  := 2.4.0
$(PKG)_SHORTV   := 2.4
$(PKG)_CHECKSUM := 778a4d38bd1161e1f0b368815514c3335da20c7584e3d07613526dcce53523bc
$(PKG)_SUBDIR   := $(PKG)-$($(PKG)_VERSION)
$(PKG)_FILE     := $(PKG)-$($(PKG)_VERSION).tar.bz2
$(PKG)_URL      := http://www.codesynthesis.com/download/odb/$($(PKG)_SHORTV)/$($(PKG)_FILE)
$(PKG)_DEPS     := gcc libodb postgresql

define $(PKG)_BUILD
    cd '$(1)' && ./configure \
        $(MXE_CONFIGURE_OPTS)
    $(MAKE) -C '$(1)' -j '$(JOBS)' install
endef
