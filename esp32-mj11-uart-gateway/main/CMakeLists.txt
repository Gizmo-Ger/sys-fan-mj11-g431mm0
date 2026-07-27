idf_component_register(
    SRCS "main.c"
    INCLUDE_DIRS "."
    EMBED_TXTFILES "index.html" "setup.html"
    REQUIRES app_update esp_app_format esp_driver_gpio esp_driver_uart esp_event
             esp_http_client esp_http_server esp_netif esp_system esp_timer esp_wifi lwip
             mbedtls nvs_flash
)
