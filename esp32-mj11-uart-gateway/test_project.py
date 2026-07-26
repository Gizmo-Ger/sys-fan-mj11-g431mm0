from pathlib import Path

root = Path(__file__).parent
main = (root / "main/main.c").read_text()
config = (root / "main/config.example.h").read_text()
partitions = (root / "partitions.csv").read_text()
cmake = (root / "CMakeLists.txt").read_text()

assert "UART_NUM_2" in main
assert "GATEWAY_UART_RX_GPIO    16" in config
assert "GATEWAY_UART_TX_GPIO    17" in config
assert "GATEWAY_TCP_PORT        2323" in config
assert "gpio_set_pull_mode(GATEWAY_UART_RX_GPIO, GPIO_PULLUP_ONLY)" in main
assert "line[used] == '\\r' || line[used] == '\\n'" in main
assert 'set(PROJECT_VER "1.9.4")' in cmake
assert '${CMAKE_PROJECT_NAME}-v${PROJECT_VER}.bin' in cmake
assert "DEPENDS gen_project_binary" in cmake
assert 'app->version, app->date, app->time' in main
assert '"Cache-Control", "no-store"' in main
assert "GATEWAY_AUTH_" not in config
assert 'nvs_open("mj11_auth"' in main
assert '#include "psa/crypto.h"' in main
assert "PSA_ALG_PBKDF2_HMAC(PSA_ALG_SHA_256)" in main
assert "PSA_KEY_DERIVATION_INPUT_COST" in main
assert "PSA_KEY_DERIVATION_INPUT_SALT" in main
assert "PSA_KEY_DERIVATION_INPUT_PASSWORD" in main
assert "mbedtls/pkcs5.h" not in main
assert "if (!auth_configured)" in main
assert (root / "main/setup.html").is_file()
assert '"/api/redfish/data"' in main
assert '"hostnics"' in main
assert '{"firmware", "/redfish/v1/UpdateService/FirmwareInventory?$expand=."}' in main
assert "#define UART_LOG_SIZE 32768" in main
assert '"/api/status"' in main
assert '"/api/log"' in main
assert "#define SYSTEM_LOG_SIZE 8192" in main
assert "esp_log_set_vprintf(system_log_vprintf)" in main
assert '"/api/system-log"' in main
assert 'filename=\\"esp32-system-log.txt\\"' in main
assert "append_uart_log(data, n)" in main
assert '"https://%s%s"' in main
assert ".timeout_ms = 6000" in main
assert "err == ESP_ERR_HTTP_EAGAIN" in main
assert "response.length = 0" in main
assert "auth_cache_valid" in main
assert "auth_fingerprint(value, fingerprint)" in main
assert "Gateway-Anmeldung: %s, %lld ms" in main
assert "Redfish %s: HTTP %d, %u Bytes, %lld ms" in main
assert "esp_wifi_set_ps(WIFI_PS_NONE)" in main
assert "CONFIG_ESP_TLS_SKIP_SERVER_CERT_VERIFY=y" in (root / "sdkconfig.defaults").read_text()
assert "CONFIG_ESP_HTTP_CLIENT_ENABLE_BASIC_AUTH=y" in (root / "sdkconfig.defaults").read_text()
assert "ota_0" in partitions and "ota_1" in partitions
readme = (root / "README.md").read_text()
guide = (root / "docs/FIRMWARE-ANLEITUNG.md").read_text()
assert "| VCC | **nicht verbinden** |" in readme
assert "GND | TX | RX | VCC" in readme
assert "e.key.toLowerCase()==='v'" in (root / "main/index.html").read_text()
assert "system.Model?.trim()||'BMC'" in (root / "main/index.html").read_text()
assert "system.BiosVersion?.trim()?null:await rf('firmware').catch(()=>null)" in (root / "main/index.html").read_text()
assert "system.BiosVersion?.trim()||firmware?.Members?.find(x=>x.Id==='BIOS')?.Version" in (root / "main/index.html").read_text()
assert "localStorage.getItem('language')" in (root / "main/index.html").read_text()
assert 'data-en="Overview"' in (root / "main/index.html").read_text()
assert 'data-en="Create account"' in (root / "main/setup.html").read_text()
assert "signalBars(level)" in (root / "main/index.html").read_text()
assert "if(ready.ok){location.reload();return}" in (root / "main/index.html").read_text()
assert 'id="statusRefresh"' not in (root / "main/index.html").read_text()
assert "complete_log_line_locked" in main
assert "uart_suppressed_lines++" in main
assert "previous line repeated %llu additional times" in main
assert '\\"suppressedLines\\":%llu' in main
assert "docs/FIRMWARE-ANLEITUNG.md" in readme
assert 'idf.py -B "C:\\tmp\\mj11-build" build' in guide
assert "MJ11 VCC        nicht verbinden" in guide
print("Projektstruktur und feste Hardwarevorgaben: OK")
