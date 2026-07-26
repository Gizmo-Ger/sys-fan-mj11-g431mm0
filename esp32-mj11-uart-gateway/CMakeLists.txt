cmake_minimum_required(VERSION 3.16)

set(PROJECT_VER "1.9.6")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(mj11_uart_gateway)

add_custom_target(
    versioned_ota ALL
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_BINARY_DIR}/${CMAKE_PROJECT_NAME}.bin"
            "${CMAKE_BINARY_DIR}/${CMAKE_PROJECT_NAME}-v${PROJECT_VER}.bin"
    DEPENDS gen_project_binary
    COMMENT "Erzeuge versioniertes OTA-Image: ${CMAKE_PROJECT_NAME}-v${PROJECT_VER}.bin"
)
