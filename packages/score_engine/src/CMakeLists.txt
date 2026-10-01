# Native core of the score engine: Verovio + the recording bridge, built as one shared library.
# Built automatically by hook/build.dart during `flutter run` / `flutter build`.
cmake_minimum_required(VERSION 3.20)
project(score_engine LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

# ccache, when installed, reuses compiled Verovio objects across clean builds (the Release
# workflow restores its cache). Set here, not through CMAKE_*_LAUNCHER in the environment:
# build hooks run with only a few variables (PATH, HOME, …) passed through.
find_program(CCACHE ccache HINTS /opt/homebrew/bin /usr/local/bin)
if(CCACHE)
  set(CMAKE_C_COMPILER_LAUNCHER ${CCACHE})
  set(CMAKE_CXX_COMPILER_LAUNCHER ${CCACHE})
endif()

set(VEROVIO ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/verovio)
if(NOT EXISTS ${VEROVIO}/src/toolkit.cpp)
  message(FATAL_ERROR "Verovio sources missing. Run `make setup` at the repository root.")
endif()

file(GLOB_RECURSE VEROVIO_SOURCES CONFIGURE_DEPENDS
  ${VEROVIO}/src/*.cpp
  ${VEROVIO}/src/*.cc
  ${VEROVIO}/libmei/dist/*.cpp
  ${VEROVIO}/libmei/addons/*.cpp)

add_library(score_engine SHARED verovio_bridge.cpp ${VEROVIO_SOURCES})
target_compile_definitions(score_engine PRIVATE VB_BUILDING_LIBRARY)
target_include_directories(score_engine PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${VEROVIO}/include/crc
  ${VEROVIO}/include/hum
  ${VEROVIO}/include/json
  ${VEROVIO}/include/midi
  ${VEROVIO}/include/pugi
  ${VEROVIO}/include/tuning-library
  ${VEROVIO}/include/utf8
  ${VEROVIO}/include/vrv
  ${VEROVIO}/include/zip
  ${VEROVIO}/libmei/dist
  ${VEROVIO}/libmei/addons)

# Verovio's warnings are not ours to fix; the bridge is our code and is held to them.
if(MSVC)
  target_compile_options(score_engine PRIVATE /bigobj /utf-8 /EHsc)
  set_source_files_properties(${VEROVIO_SOURCES} PROPERTIES COMPILE_OPTIONS /W0)
  set_source_files_properties(verovio_bridge.cpp PROPERTIES COMPILE_OPTIONS /W3)
else()
  set_source_files_properties(${VEROVIO_SOURCES} PROPERTIES COMPILE_OPTIONS -w)
  set_source_files_properties(verovio_bridge.cpp PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra;-Wno-unused-parameter")
endif()
