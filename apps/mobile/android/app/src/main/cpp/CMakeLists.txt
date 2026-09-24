cmake_minimum_required(VERSION 3.22.1)
project(persalone_halo_native C CXX)

include(FetchContent)
FetchContent_Declare(
  brilliant_sdk
  GIT_REPOSITORY https://github.com/brilliantlabsAR/brilliant_sdk.git
  GIT_TAG 462dff4795cffb85248ab1d2f92d4f319adb03d3
  GIT_SHALLOW FALSE
)
FetchContent_MakeAvailable(brilliant_sdk)
add_subdirectory(
  ${brilliant_sdk_SOURCE_DIR}/flutter/packages/simple_brilliant_app/example/realtime_openai/native/liblc3
  ${CMAKE_BINARY_DIR}/liblc3
)
install(TARGETS liblc3 LIBRARY DESTINATION ${CMAKE_LIBRARY_OUTPUT_DIRECTORY})