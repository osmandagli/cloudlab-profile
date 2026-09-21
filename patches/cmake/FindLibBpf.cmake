# Copyright (c) Meta Platforms, Inc. and affiliates.
# This source code is licensed under the Apache 2.0 license found in the
# LICENSE file in the root directory of this source tree.

# - Find libbpf
# Find the libbpf library and includes
#
# LIBBPF_INCLUDE_DIR - where to find bpf/libbpf.h, etc.
# LIBBPF_LIBRARIES - List of libraries when using libbpf.
# LIBBPF_FOUND - True if libbpf found.
find_path(LIBBPF_INCLUDE_DIR
  NAMES bpf/libbpf.h
  HINTS ${LIBBPF_ROOT_DIR}/include)

find_library(LIBBPF_LIBRARIES
  NAMES bpf
  HINTS ${LIBBPF_ROOT_DIR}/lib)

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(LibBpf DEFAULT_MSG LIBBPF_LIBRARIES LIBBPF_INCLUDE_DIR)

mark_as_advanced(
  LIBBPF_LIBRARIES
  LIBBPF_INCLUDE_DIR
)

find_library(LIBELF_LIBRARIES NAMES elf)

if(NOT TARGET libbpf)
    if("${LIBBPF_LIBRARIES}" MATCHES ".*.a$")
        add_library(libbpf STATIC IMPORTED)
    else()
        add_library(libbpf SHARED IMPORTED)
    endif()
    set_target_properties(
        libbpf
        PROPERTIES
            IMPORTED_LOCATION ${LIBBPF_LIBRARIES}
            INTERFACE_INCLUDE_DIRECTORIES ${LIBBPF_INCLUDE_DIR}
        INTERFACE_LINK_LIBRARIES "${LIBELF_LIBRARIES};z"
    )
endif()