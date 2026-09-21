# Copyright (c) Meta Platforms, Inc. and affiliates.
# This source code is licensed under the Apache 2.0 license found in the
# LICENSE file in the root directory of this source tree.

# - Find libxdp
# Find the libxdp library and includes
#
# LIBXDP_INCLUDE_DIR - where to find xdp/xsk.h, etc.
# LIBXDP_LIBRARIES - List of libraries when using libxdp.
# LIBXDP_FOUND - True if libxdp found.
find_path(LIBXDP_INCLUDE_DIR
  NAMES xdp/xsk.h
  HINTS ${LIBXDP_ROOT_DIR}/include)

find_library(LIBXDP_LIBRARIES
  NAMES xdp
  HINTS ${LIBXDP_ROOT_DIR}/lib)

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(LibXdp DEFAULT_MSG LIBXDP_LIBRARIES LIBXDP_INCLUDE_DIR)

mark_as_advanced(
  LIBXDP_LIBRARIES
  LIBXDP_INCLUDE_DIR
)

find_library(LIBELF_LIBRARIES NAMES elf)

if(NOT TARGET libxdp)
    if("${LIBXDP_LIBRARIES}" MATCHES ".*.a$")
        add_library(libxdp STATIC IMPORTED)
    else()
        add_library(libxdp SHARED IMPORTED)
    endif()
    set_target_properties(
        libxdp
        PROPERTIES
            IMPORTED_LOCATION ${LIBXDP_LIBRARIES}
            INTERFACE_INCLUDE_DIRECTORIES ${LIBXDP_INCLUDE_DIR}
        INTERFACE_LINK_LIBRARIES "libbpf"
    )
endif()