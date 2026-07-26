#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>

#include "config.h"
#include "driver/gpio.h"
#include "driver/uart.h"
#include "esp_app_desc.h"
#include "esp_event.h"
#include "esp_http_client.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "esp_task_wdt.h"
#include "esp_timer.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lwip/inet.h"
#include "lwip/sockets.h"
#include "mbedtls/base64.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "psa/crypto.h"

#define UART_PORT UART_NUM_2
#define IO_BUFFER_SIZE 512
#define AUTH_USER_MAX 32
#define AUTH_PASSWORD_MAX 64
#define AUTH_SALT_SIZE 16
#define AUTH_HASH_SIZE 32
#define AUTH_CACHE_KEY_SIZE 32
#define AUTH_PBKDF2_ITERATIONS 20000
#define REDFISH_RESPONSE_MAX 32768
#define UART_LOG_SIZE 32768
#define UART_LOG_LINE_MAX 512
#define UART_LOG_MARKER_MAX 96
#define UART_LOG_SNAPSHOT_MAX (UART_LOG_SIZE + UART_LOG_LINE_MAX + UART_LOG_MARKER_MAX)
#define SYSTEM_LOG_SIZE 8192
#define SYSTEM_LOG_LINE_MAX 512

static const char *TAG = "mj11-gateway";
static httpd_handle_t http_server;
static volatile int tcp_client = -1;
static volatile int ws_client = -1;
static portMUX_TYPE client_lock = portMUX_INITIALIZER_UNLOCKED;
static esp_timer_handle_t reconnect_timer;
static unsigned reconnect_delay_s = 1;
static bool auth_configured;
static char auth_user[AUTH_USER_MAX + 1];
static uint8_t auth_salt[AUTH_SALT_SIZE];
static uint8_t auth_hash[AUTH_HASH_SIZE];
static uint8_t auth_cache_key[AUTH_CACHE_KEY_SIZE];
static uint8_t auth_cache_hash[AUTH_HASH_SIZE];
static bool auth_cache_valid;
static char bmc_host[16];
static char bmc_user[AUTH_USER_MAX + 1];
static char bmc_password[AUTH_PASSWORD_MAX + 1];
static uint8_t uart_log[UART_LOG_SIZE];
static size_t uart_log_head;
static size_t uart_log_length;
static uint8_t uart_log_line[UART_LOG_LINE_MAX];
static size_t uart_log_line_length;
static uint8_t uart_log_last_line[UART_LOG_LINE_MAX];
static size_t uart_log_last_line_length;
static uint64_t uart_log_repeats;
static uint64_t uart_suppressed_lines;
static uint64_t uart_rx_bytes;
static uint64_t uart_tx_bytes;
static SemaphoreHandle_t uart_log_mutex;
static uint8_t system_log[SYSTEM_LOG_SIZE];
static size_t system_log_head;
static size_t system_log_length;
static portMUX_TYPE system_log_lock = portMUX_INITIALIZER_UNLOCKED;
static vprintf_like_t console_vprintf;

extern const unsigned char index_html_start[] asm("_binary_index_html_start");
extern const unsigned char index_html_end[] asm("_binary_index_html_end");
extern const unsigned char setup_html_start[] asm("_binary_setup_html_start");
extern const unsigned char setup_html_end[] asm("_binary_setup_html_end");

_Static_assert(sizeof(GATEWAY_WIFI_SSID) <= 33, "WLAN-SSID ist zu lang");
_Static_assert(sizeof(GATEWAY_WIFI_PASSWORD) <= 65, "WLAN-Passwort ist zu lang");
_Static_assert(sizeof(GATEWAY_HOSTNAME) <= 33, "Hostname ist zu lang");
_Static_assert(GATEWAY_UART_BAUD > 0, "UART-Baudrate muss groesser als 0 sein");

static void append_system_log(const uint8_t *data, size_t length)
{
    portENTER_CRITICAL(&system_log_lock);
    if (length >= SYSTEM_LOG_SIZE) {
        memcpy(system_log, data + length - SYSTEM_LOG_SIZE, SYSTEM_LOG_SIZE);
        system_log_head = 0;
        system_log_length = SYSTEM_LOG_SIZE;
    } else {
        size_t first = MIN(length, SYSTEM_LOG_SIZE - system_log_head);
        memcpy(system_log + system_log_head, data, first);
        memcpy(system_log, data + first, length - first);
        system_log_head = (system_log_head + length) % SYSTEM_LOG_SIZE;
        system_log_length = MIN(system_log_length + length, SYSTEM_LOG_SIZE);
    }
    portEXIT_CRITICAL(&system_log_lock);
}

static int system_log_vprintf(const char *format, va_list args)
{
    char line[SYSTEM_LOG_LINE_MAX];
    va_list copy;
    va_copy(copy, args);
    int length = vsnprintf(line, sizeof(line), format, copy);
    va_end(copy);
    if (length > 0) {
        append_system_log((const uint8_t *)line,
                          MIN((size_t)length, sizeof(line) - 1));
    }
    return console_vprintf ? console_vprintf(format, args) : vprintf(format, args);
}

static size_t snapshot_system_log(uint8_t *output)
{
    portENTER_CRITICAL(&system_log_lock);
    size_t length = system_log_length;
    size_t start = (system_log_head + SYSTEM_LOG_SIZE - length) % SYSTEM_LOG_SIZE;
    size_t first = MIN(length, SYSTEM_LOG_SIZE - start);
    memcpy(output, system_log + start, first);
    memcpy(output + first, system_log, length - first);
    portEXIT_CRITICAL(&system_log_lock);
    return length;
}

static void replace_client(volatile int *slot, int fd)
{
    int old;
    portENTER_CRITICAL(&client_lock);
    old = *slot;
    *slot = fd;
    portEXIT_CRITICAL(&client_lock);
    if (old >= 0 && old != fd) {
        shutdown(old, SHUT_RDWR);
    }
}

static void ring_write_locked(const uint8_t *data, size_t length)
{
    if (length >= UART_LOG_SIZE) {
        memcpy(uart_log, data + length - UART_LOG_SIZE, UART_LOG_SIZE);
        uart_log_head = 0;
        uart_log_length = UART_LOG_SIZE;
    } else {
        size_t first = MIN(length, UART_LOG_SIZE - uart_log_head);
        memcpy(uart_log + uart_log_head, data, first);
        memcpy(uart_log, data + first, length - first);
        uart_log_head = (uart_log_head + length) % UART_LOG_SIZE;
        uart_log_length = MIN(uart_log_length + length, UART_LOG_SIZE);
    }
}

static size_t repeat_marker(char *marker, size_t capacity, uint64_t repeats)
{
    int length = snprintf(marker, capacity,
                          "[previous line repeated %llu additional times]\r\n",
                          (unsigned long long)repeats);
    return length > 0 ? MIN((size_t)length, capacity - 1) : 0;
}

static void flush_repeats_locked(void)
{
    if (uart_log_repeats == 0) {
        return;
    }
    char marker[UART_LOG_MARKER_MAX];
    size_t length = repeat_marker(marker, sizeof(marker), uart_log_repeats);
    ring_write_locked((const uint8_t *)marker, length);
    uart_log_repeats = 0;
}

static void complete_log_line_locked(void)
{
    if (uart_log_line_length == uart_log_last_line_length &&
        uart_log_line_length > 0 &&
        memcmp(uart_log_line, uart_log_last_line, uart_log_line_length) == 0) {
        uart_log_repeats++;
        uart_suppressed_lines++;
    } else {
        flush_repeats_locked();
        ring_write_locked(uart_log_line, uart_log_line_length);
        memcpy(uart_log_last_line, uart_log_line, uart_log_line_length);
        uart_log_last_line_length = uart_log_line_length;
    }
    uart_log_line_length = 0;
}

static void append_uart_log(const uint8_t *data, size_t length)
{
    xSemaphoreTake(uart_log_mutex, portMAX_DELAY);
    uart_rx_bytes += length;
    for (size_t i = 0; i < length; i++) {
        uart_log_line[uart_log_line_length++] = data[i];
        if (data[i] == '\n') {
            complete_log_line_locked();
        } else if (uart_log_line_length == UART_LOG_LINE_MAX) {
            flush_repeats_locked();
            ring_write_locked(uart_log_line, uart_log_line_length);
            uart_log_line_length = 0;
            uart_log_last_line_length = 0;
        }
    }
    xSemaphoreGive(uart_log_mutex);
}

static int write_uart(const uint8_t *data, size_t length)
{
    int written = uart_write_bytes(UART_PORT, data, length);
    if (written > 0) {
        xSemaphoreTake(uart_log_mutex, portMAX_DELAY);
        uart_tx_bytes += written;
        xSemaphoreGive(uart_log_mutex);
    }
    return written;
}

static size_t snapshot_uart_log(uint8_t *output)
{
    xSemaphoreTake(uart_log_mutex, portMAX_DELAY);
    size_t length = uart_log_length;
    size_t start = (uart_log_head + UART_LOG_SIZE - length) % UART_LOG_SIZE;
    size_t first = MIN(length, UART_LOG_SIZE - start);
    memcpy(output, uart_log + start, first);
    memcpy(output + first, uart_log, length - first);
    if (uart_log_repeats > 0) {
        length += repeat_marker((char *)output + length,
                                UART_LOG_MARKER_MAX, uart_log_repeats);
    }
    memcpy(output + length, uart_log_line, uart_log_line_length);
    length += uart_log_line_length;
    xSemaphoreGive(uart_log_mutex);
    return length;
}

static bool derive_password(const char *password, const uint8_t *salt, uint8_t *hash)
{
    psa_key_derivation_operation_t operation = PSA_KEY_DERIVATION_OPERATION_INIT;
    psa_status_t status = psa_crypto_init();
    if (status == PSA_SUCCESS) {
        status = psa_key_derivation_setup(
            &operation, PSA_ALG_PBKDF2_HMAC(PSA_ALG_SHA_256));
    }
    if (status == PSA_SUCCESS) {
        status = psa_key_derivation_input_integer(
            &operation, PSA_KEY_DERIVATION_INPUT_COST, AUTH_PBKDF2_ITERATIONS);
    }
    if (status == PSA_SUCCESS) {
        status = psa_key_derivation_input_bytes(
            &operation, PSA_KEY_DERIVATION_INPUT_SALT, salt, AUTH_SALT_SIZE);
    }
    if (status == PSA_SUCCESS) {
        status = psa_key_derivation_input_bytes(
            &operation, PSA_KEY_DERIVATION_INPUT_PASSWORD,
            (const uint8_t *)password, strlen(password));
    }
    if (status == PSA_SUCCESS) {
        status = psa_key_derivation_output_bytes(&operation, hash, AUTH_HASH_SIZE);
    }
    psa_key_derivation_abort(&operation);
    return status == PSA_SUCCESS;
}

static bool password_matches(const char *password)
{
    uint8_t candidate[AUTH_HASH_SIZE];
    if (!derive_password(password, auth_salt, candidate)) {
        return false;
    }
    unsigned difference = 0;
    for (size_t i = 0; i < sizeof(candidate); i++) {
        difference |= candidate[i] ^ auth_hash[i];
    }
    return difference == 0;
}

static bool auth_fingerprint(const char *value, uint8_t *fingerprint)
{
    uint8_t input[AUTH_CACHE_KEY_SIZE + 160];
    size_t value_length = strlen(value);
    size_t hash_length = 0;
    if (value_length >= 160) return false;
    memcpy(input, auth_cache_key, sizeof(auth_cache_key));
    memcpy(input + sizeof(auth_cache_key), value, value_length);
    return psa_crypto_init() == PSA_SUCCESS &&
           psa_hash_compute(PSA_ALG_SHA_256, input,
                            sizeof(auth_cache_key) + value_length,
                            fingerprint, AUTH_HASH_SIZE,
                            &hash_length) == PSA_SUCCESS &&
           hash_length == AUTH_HASH_SIZE;
}

static bool constant_time_equal(const uint8_t *left, const uint8_t *right,
                                size_t length)
{
    unsigned difference = 0;
    for (size_t i = 0; i < length; i++) difference |= left[i] ^ right[i];
    return difference == 0;
}

static void load_auth(void)
{
    nvs_handle_t nvs = 0;
    size_t user_size = sizeof(auth_user);
    size_t salt_size = sizeof(auth_salt);
    size_t hash_size = sizeof(auth_hash);
    if (nvs_open("mj11_auth", NVS_READONLY, &nvs) != ESP_OK) {
        return;
    }
    auth_configured =
        nvs_get_str(nvs, "user", auth_user, &user_size) == ESP_OK &&
        nvs_get_blob(nvs, "salt", auth_salt, &salt_size) == ESP_OK &&
        nvs_get_blob(nvs, "hash", auth_hash, &hash_size) == ESP_OK &&
        user_size > 1 && salt_size == AUTH_SALT_SIZE && hash_size == AUTH_HASH_SIZE;
    nvs_close(nvs);
}

static esp_err_t save_auth(const char *user, const char *password)
{
    uint8_t salt[AUTH_SALT_SIZE];
    uint8_t hash[AUTH_HASH_SIZE];
    esp_fill_random(salt, sizeof(salt));
    if (!derive_password(password, salt, hash)) {
        return ESP_FAIL;
    }

    nvs_handle_t nvs = 0;
    esp_err_t err = nvs_open("mj11_auth", NVS_READWRITE, &nvs);
    if (err == ESP_OK) err = nvs_set_str(nvs, "user", user);
    if (err == ESP_OK) err = nvs_set_blob(nvs, "salt", salt, sizeof(salt));
    if (err == ESP_OK) err = nvs_set_blob(nvs, "hash", hash, sizeof(hash));
    if (err == ESP_OK) err = nvs_commit(nvs);
    if (nvs) nvs_close(nvs);
    if (err == ESP_OK) {
        strcpy(auth_user, user);
        memcpy(auth_salt, salt, sizeof(auth_salt));
        memcpy(auth_hash, hash, sizeof(auth_hash));
        auth_configured = true;
        auth_cache_valid = false;
    }
    return err;
}

static bool authenticated(httpd_req_t *req)
{
    char value[160];
    unsigned char decoded[AUTH_USER_MAX + AUTH_PASSWORD_MAX + 2];
    uint8_t fingerprint[AUTH_HASH_SIZE];
    size_t decoded_len = 0;
    if (auth_configured &&
        httpd_req_get_hdr_value_str(req, "Authorization", value, sizeof(value)) == ESP_OK &&
        strncmp(value, "Basic ", 6) == 0 &&
        auth_fingerprint(value, fingerprint)) {
        if (auth_cache_valid &&
            constant_time_equal(fingerprint, auth_cache_hash,
                                sizeof(auth_cache_hash))) {
            return true;
        }
        if (mbedtls_base64_decode(decoded, sizeof(decoded) - 1, &decoded_len,
                                  (const unsigned char *)value + 6,
                                  strlen(value + 6)) == 0) {
            decoded[decoded_len] = '\0';
            char *colon = strchr((char *)decoded, ':');
            if (colon) {
                *colon = '\0';
                int64_t started = esp_timer_get_time();
                bool matches = strcmp((char *)decoded, auth_user) == 0 &&
                               password_matches(colon + 1);
                ESP_LOGI(TAG, "Gateway-Anmeldung: %s, %lld ms",
                         matches ? "erfolgreich" : "abgelehnt",
                         (long long)((esp_timer_get_time() - started) / 1000));
                if (matches) {
                    memcpy(auth_cache_hash, fingerprint,
                           sizeof(auth_cache_hash));
                    auth_cache_valid = true;
                    return true;
                }
            }
        }
    }
    if (!auth_configured) {
        httpd_resp_send_err(req, HTTPD_403_FORBIDDEN,
                            "Ersteinrichtung erforderlich");
        return false;
    }
    httpd_resp_set_status(req, "401 Unauthorized");
    httpd_resp_set_hdr(req, "WWW-Authenticate", "Basic realm=\"MJ11 UART\"");
    httpd_resp_send(req, "Authentifizierung erforderlich\n", HTTPD_RESP_USE_STRLEN);
    return false;
}

static esp_err_t index_handler(httpd_req_t *req)
{
    if (!auth_configured) {
        httpd_resp_set_hdr(req, "Cache-Control", "no-store");
        httpd_resp_set_type(req, "text/html; charset=utf-8");
        return httpd_resp_send(req, (const char *)setup_html_start,
                               setup_html_end - setup_html_start);
    }
    if (!authenticated(req)) {
        return ESP_OK;
    }
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_type(req, "text/html; charset=utf-8");
    return httpd_resp_send(req, (const char *)index_html_start,
                           index_html_end - index_html_start);
}

static int hex_value(char value)
{
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
}

static bool url_decode(char *value)
{
    char *read = value;
    char *write = value;
    while (*read) {
        if (*read == '+') {
            *write++ = ' ';
            read++;
        } else if (*read == '%') {
            if (!read[1] || !read[2]) return false;
            int high = hex_value(read[1]);
            int low = hex_value(read[2]);
            if (high < 0 || low < 0 || (high == 0 && low == 0)) return false;
            *write++ = (char)((high << 4) | low);
            read += 3;
        } else {
            *write++ = *read++;
        }
    }
    *write = '\0';
    return true;
}

static bool valid_user(const char *user)
{
    size_t length = strlen(user);
    if (length < 1 || length > AUTH_USER_MAX) return false;
    for (const char *p = user; *p; p++) {
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') ||
              (*p >= '0' && *p <= '9') || *p == '.' || *p == '_' || *p == '-')) {
            return false;
        }
    }
    return true;
}

static int receive_body(httpd_req_t *req, char *body, size_t size)
{
    if (req->content_len <= 0 || req->content_len >= size) return -1;
    int received = 0;
    while (received < req->content_len) {
        int n = httpd_req_recv(req, body + received, req->content_len - received);
        if (n == HTTPD_SOCK_ERR_TIMEOUT) continue;
        if (n <= 0) return -1;
        received += n;
    }
    body[received] = '\0';
    return received;
}

static esp_err_t setup_handler(httpd_req_t *req)
{
    if (auth_configured) {
        httpd_resp_send_err(req, HTTPD_403_FORBIDDEN, "Konto ist bereits eingerichtet");
        return ESP_OK;
    }
    char body[256];
    if (receive_body(req, body, sizeof(body)) < 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Ungueltige Eingabe");
        return ESP_OK;
    }

    static const char prefix[] = "username=";
    char *separator = strstr(body, "&password=");
    if (strncmp(body, prefix, sizeof(prefix) - 1) != 0 || !separator) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Felder fehlen");
        return ESP_OK;
    }
    *separator = '\0';
    char *user = body + sizeof(prefix) - 1;
    char *password = separator + strlen("&password=");
    if (!url_decode(user) || !url_decode(password) || !valid_user(user) ||
        strlen(password) < 12 || strlen(password) > AUTH_PASSWORD_MAX) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST,
                            "Benutzername oder Passwort ungueltig");
        return ESP_OK;
    }
    esp_err_t err = save_auth(user, password);
    memset(password, 0, strlen(password));
    if (err != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "Konto konnte nicht gespeichert werden");
        return ESP_OK;
    }
    httpd_resp_set_status(req, "303 See Other");
    httpd_resp_set_hdr(req, "Location", "/");
    return httpd_resp_send(req, NULL, 0);
}

static bool redfish_configured(void)
{
    return bmc_host[0] && bmc_user[0] && bmc_password[0];
}

static esp_err_t fetch_redfish(const char *path, char **json, size_t *length,
                               int *http_status);

static esp_err_t redfish_config_handler(httpd_req_t *req)
{
    if (!authenticated(req)) return ESP_OK;

    char body[384];
    if (receive_body(req, body, sizeof(body)) < 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Ungueltige Eingabe");
        return ESP_OK;
    }
    static const char host_prefix[] = "host=";
    char *user_field = strstr(body, "&username=");
    char *password_field = strstr(body, "&password=");
    if (strncmp(body, host_prefix, sizeof(host_prefix) - 1) != 0 ||
        !user_field || !password_field || password_field < user_field) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Felder fehlen");
        return ESP_OK;
    }
    *user_field = '\0';
    *password_field = '\0';
    char *host = body + sizeof(host_prefix) - 1;
    char *user = user_field + strlen("&username=");
    char *password = password_field + strlen("&password=");
    struct in_addr address;
    if (!url_decode(host) || !url_decode(user) || !url_decode(password) ||
        inet_pton(AF_INET, host, &address) != 1 || !valid_user(user) ||
        strlen(password) < 1 || strlen(password) > AUTH_PASSWORD_MAX) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST,
                            "BMC-IP oder Zugangsdaten ungueltig");
        return ESP_OK;
    }
    strcpy(bmc_host, host);
    strcpy(bmc_user, user);
    memset(bmc_password, 0, sizeof(bmc_password));
    strcpy(bmc_password, password);
    memset(password, 0, strlen(password));

    char *probe;
    size_t probe_length;
    int status;
    esp_err_t err = fetch_redfish("/redfish/v1/Managers/Self",
                                  &probe, &probe_length, &status);
    if (err != ESP_OK) {
        memset(bmc_host, 0, sizeof(bmc_host));
        memset(bmc_user, 0, sizeof(bmc_user));
        memset(bmc_password, 0, sizeof(bmc_password));
        char message[112];
        snprintf(message, sizeof(message),
                 "Redfish-Anmeldung fehlgeschlagen: HTTP %d, %s",
                 status, esp_err_to_name(err));
        httpd_resp_send_err(req, HTTPD_401_UNAUTHORIZED, message);
        return ESP_OK;
    }
    free(probe);
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_sendstr(req, "{\"configured\":true}");
}

static esp_err_t redfish_config_status_handler(httpd_req_t *req)
{
    if (!authenticated(req)) return ESP_OK;
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_sendstr(req, redfish_configured()
                                  ? "{\"configured\":true}"
                                  : "{\"configured\":false}");
}

static esp_err_t redfish_clear_handler(httpd_req_t *req)
{
    if (!authenticated(req)) return ESP_OK;
    memset(bmc_host, 0, sizeof(bmc_host));
    memset(bmc_user, 0, sizeof(bmc_user));
    memset(bmc_password, 0, sizeof(bmc_password));
    return httpd_resp_send(req, NULL, 0);
}

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} redfish_response_t;

static esp_err_t redfish_event(esp_http_client_event_t *event)
{
    redfish_response_t *response = event->user_data;
    if (event->event_id == HTTP_EVENT_ON_DATA && event->data_len > 0) {
        if (response->length + event->data_len >= response->capacity) {
            return ESP_ERR_NO_MEM;
        }
        memcpy(response->data + response->length, event->data, event->data_len);
        response->length += event->data_len;
        response->data[response->length] = '\0';
    }
    return ESP_OK;
}

static esp_err_t fetch_redfish(const char *path, char **json, size_t *length,
                               int *http_status)
{
    int64_t started = esp_timer_get_time();
    char url[160];
    snprintf(url, sizeof(url), "https://%s%s", bmc_host, path);
    redfish_response_t response = {
        .data = malloc(REDFISH_RESPONSE_MAX),
        .capacity = REDFISH_RESPONSE_MAX
    };
    if (!response.data) return ESP_ERR_NO_MEM;
    response.data[0] = '\0';

    esp_http_client_config_t config = {
        .url = url,
        .username = bmc_user,
        .password = bmc_password,
        .auth_type = HTTP_AUTH_TYPE_BASIC,
        .event_handler = redfish_event,
        .user_data = &response,
        .timeout_ms = 6000,
        .buffer_size = 2048,
        .buffer_size_tx = 1024
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    esp_err_t err = client ? esp_http_client_perform(client) : ESP_ERR_NO_MEM;
    if (err == ESP_ERR_HTTP_EAGAIN) {
        ESP_LOGW(TAG, "Redfish %s: Empfangstimeout, ein neuer Versuch", path);
        response.length = 0;
        response.data[0] = '\0';
        err = esp_http_client_perform(client);
    }
    int status = client ? esp_http_client_get_status_code(client) : 0;
    *http_status = status;
    if (client) esp_http_client_cleanup(client);
    if (err != ESP_OK || status != 200 || response.length == 0) {
        ESP_LOGW(TAG, "Redfish %s fehlgeschlagen: %s, HTTP %d, %lld ms",
                 path, esp_err_to_name(err), status,
                 (long long)((esp_timer_get_time() - started) / 1000));
        free(response.data);
        return err == ESP_OK ? ESP_FAIL : err;
    }
    ESP_LOGI(TAG, "Redfish %s: HTTP %d, %u Bytes, %lld ms",
             path, status, (unsigned)response.length,
             (long long)((esp_timer_get_time() - started) / 1000));
    *json = response.data;
    *length = response.length;
    return ESP_OK;
}

static esp_err_t redfish_data_handler(httpd_req_t *req)
{
    if (!authenticated(req)) return ESP_OK;
    if (!redfish_configured()) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST,
                            "Redfish-Zugangsdaten fehlen");
        return ESP_OK;
    }
    char query[48];
    char kind[16];
    if (httpd_req_get_url_query_str(req, query, sizeof(query)) != ESP_OK ||
        httpd_query_key_value(query, "kind", kind, sizeof(kind)) != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Datentyp fehlt");
        return ESP_OK;
    }
    static const struct {
        const char *kind;
        const char *path;
    } endpoints[] = {
        {"system", "/redfish/v1/Systems/Self"},
        {"firmware", "/redfish/v1/UpdateService/FirmwareInventory?$expand=."},
        {"manager", "/redfish/v1/Managers/Self"},
        {"thermal", "/redfish/v1/Chassis/Self/Thermal"},
        {"power", "/redfish/v1/Chassis/Self/Power"},
        {"network", "/redfish/v1/Managers/Self/EthernetInterfaces?$expand=."},
        {"hostnics", "/redfish/v1/Systems/Self/EthernetInterfaces?$expand=."}
    };
    const char *path = NULL;
    for (size_t i = 0; i < sizeof(endpoints) / sizeof(endpoints[0]); i++) {
        if (strcmp(kind, endpoints[i].kind) == 0) {
            path = endpoints[i].path;
            break;
        }
    }
    if (!path) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Datentyp ungueltig");
        return ESP_OK;
    }
    char *json;
    size_t length;
    int status;
    esp_err_t err = fetch_redfish(path, &json, &length, &status);
    if (err != ESP_OK) {
        char message[112];
        snprintf(message, sizeof(message),
                 "Redfish-Abfrage fehlgeschlagen: HTTP %d, %s",
                 status, esp_err_to_name(err));
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            message);
        return ESP_OK;
    }
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_type(req, "application/json");
    esp_err_t send_err = httpd_resp_send(req, json, length);
    free(json);
    return send_err;
}

static esp_err_t info_handler(httpd_req_t *req)
{
    if (!authenticated(req)) {
        return ESP_OK;
    }
    const esp_app_desc_t *app = esp_app_get_description();
    char info[96];
    snprintf(info, sizeof(info), "v%s · %s %s", app->version, app->date, app->time);
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_type(req, "text/plain; charset=utf-8");
    return httpd_resp_sendstr(req, info);
}

static esp_err_t status_handler(httpd_req_t *req)
{
    if (!authenticated(req)) {
        return ESP_OK;
    }
    wifi_ap_record_t ap = {0};
    bool wifi_connected = esp_wifi_sta_get_ap_info(&ap) == ESP_OK;
    uint64_t rx_bytes;
    uint64_t tx_bytes;
    uint64_t suppressed_lines;
    size_t log_bytes;
    xSemaphoreTake(uart_log_mutex, portMAX_DELAY);
    rx_bytes = uart_rx_bytes;
    tx_bytes = uart_tx_bytes;
    suppressed_lines = uart_suppressed_lines;
    log_bytes = uart_log_length;
    xSemaphoreGive(uart_log_mutex);

    char json[512];
    int length = snprintf(
        json, sizeof(json),
        "{\"uptimeSeconds\":%llu,\"freeHeap\":%u,\"minimumFreeHeap\":%u,"
        "\"wifiConnected\":%s,\"wifiRssi\":%d,\"tcpConnected\":%s,"
        "\"websocketConnected\":%s,\"uartRxBytes\":%llu,\"uartTxBytes\":%llu,"
        "\"uartBaud\":%d,\"logBytes\":%u,\"logCapacity\":%d,"
        "\"suppressedLines\":%llu}",
        (unsigned long long)(esp_timer_get_time() / 1000000ULL),
        (unsigned)esp_get_free_heap_size(),
        (unsigned)esp_get_minimum_free_heap_size(),
        wifi_connected ? "true" : "false", wifi_connected ? ap.rssi : 0,
        tcp_client >= 0 ? "true" : "false",
        ws_client >= 0 ? "true" : "false",
        (unsigned long long)rx_bytes, (unsigned long long)tx_bytes,
        GATEWAY_UART_BAUD, (unsigned)log_bytes, UART_LOG_SIZE,
        (unsigned long long)suppressed_lines);
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, json, length);
}

static esp_err_t log_handler(httpd_req_t *req)
{
    if (!authenticated(req)) {
        return ESP_OK;
    }
    uint8_t *snapshot = malloc(UART_LOG_SNAPSHOT_MAX);
    if (!snapshot) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "Nicht genug RAM fuer Logdownload");
        return ESP_OK;
    }
    size_t length = snapshot_uart_log(snapshot);
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_hdr(req, "Content-Disposition",
                       "attachment; filename=\"mj11-uart-log.txt\"");
    httpd_resp_set_type(req, "text/plain; charset=utf-8");
    esp_err_t err = httpd_resp_send(req, (const char *)snapshot, length);
    free(snapshot);
    return err;
}

static esp_err_t system_log_handler(httpd_req_t *req)
{
    if (!authenticated(req)) {
        return ESP_OK;
    }
    uint8_t *snapshot = malloc(SYSTEM_LOG_SIZE);
    if (!snapshot) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR,
                            "Nicht genug RAM fuer Systemlog");
        return ESP_OK;
    }
    size_t length = snapshot_system_log(snapshot);
    httpd_resp_set_hdr(req, "Cache-Control", "no-store");
    httpd_resp_set_hdr(req, "Content-Disposition",
                       "attachment; filename=\"esp32-system-log.txt\"");
    httpd_resp_set_type(req, "text/plain; charset=utf-8");
    esp_err_t err = httpd_resp_send(req, (const char *)snapshot, length);
    free(snapshot);
    return err;
}

static esp_err_t websocket_handler(httpd_req_t *req)
{
    if (req->method == HTTP_GET) {
        return ESP_OK;
    }

    httpd_ws_frame_t frame = {0};
    frame.type = HTTPD_WS_TYPE_BINARY;
    esp_err_t err = httpd_ws_recv_frame(req, &frame, 0);
    if (err != ESP_OK || frame.len > IO_BUFFER_SIZE) {
        return err == ESP_OK ? ESP_ERR_INVALID_SIZE : err;
    }
    if (frame.len == 0) {
        return ESP_OK;
    }

    uint8_t data[IO_BUFFER_SIZE];
    frame.payload = data;
    err = httpd_ws_recv_frame(req, &frame, frame.len);
    if (err == ESP_OK && (frame.type == HTTPD_WS_TYPE_TEXT ||
                          frame.type == HTTPD_WS_TYPE_BINARY)) {
        write_uart(data, frame.len);
    }
    return err;
}

static esp_err_t websocket_auth_handler(httpd_req_t *req)
{
    if (!authenticated(req)) {
        return ESP_FAIL;
    }
    replace_client(&ws_client, httpd_req_to_sockfd(req));
    return ESP_OK;
}

static esp_err_t ota_handler(httpd_req_t *req)
{
    if (!authenticated(req)) {
        return ESP_OK;
    }
    if (req->content_len <= 0) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "Leere Firmware");
        return ESP_FAIL;
    }

    const esp_partition_t *partition = esp_ota_get_next_update_partition(NULL);
    esp_ota_handle_t handle = 0;
    esp_err_t err = partition ? esp_ota_begin(partition, req->content_len, &handle)
                              : ESP_ERR_NOT_FOUND;
    uint8_t data[IO_BUFFER_SIZE];
    int remaining = req->content_len;

    while (err == ESP_OK && remaining > 0) {
        int received = httpd_req_recv(req, (char *)data, MIN(remaining, sizeof(data)));
        if (received == HTTPD_SOCK_ERR_TIMEOUT) {
            continue;
        }
        if (received <= 0) {
            err = ESP_FAIL;
            break;
        }
        err = esp_ota_write(handle, data, received);
        remaining -= received;
    }

    if (err == ESP_OK) {
        err = esp_ota_end(handle);
    } else if (handle) {
        esp_ota_abort(handle);
    }
    if (err == ESP_OK) {
        err = esp_ota_set_boot_partition(partition);
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "OTA fehlgeschlagen: %s", esp_err_to_name(err));
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, esp_err_to_name(err));
        return ESP_FAIL;
    }

    httpd_resp_sendstr(req, "Update erfolgreich. Neustart …\n");
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_restart();
    return ESP_OK;
}

static void start_http_server(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.max_uri_handlers = 12;
    config.lru_purge_enable = true;
    ESP_ERROR_CHECK(httpd_start(&http_server, &config));

    const httpd_uri_t index_uri = {
        .uri = "/", .method = HTTP_GET, .handler = index_handler
    };
    const httpd_uri_t ws_uri = {
        .uri = "/ws", .method = HTTP_GET, .handler = websocket_handler,
        .is_websocket = true, .ws_pre_handshake_cb = websocket_auth_handler
    };
    const httpd_uri_t ota_uri = {
        .uri = "/ota", .method = HTTP_POST, .handler = ota_handler
    };
    const httpd_uri_t info_uri = {
        .uri = "/info", .method = HTTP_GET, .handler = info_handler
    };
    const httpd_uri_t status_uri = {
        .uri = "/api/status", .method = HTTP_GET, .handler = status_handler
    };
    const httpd_uri_t log_uri = {
        .uri = "/api/log", .method = HTTP_GET, .handler = log_handler
    };
    const httpd_uri_t system_log_uri = {
        .uri = "/api/system-log", .method = HTTP_GET,
        .handler = system_log_handler
    };
    const httpd_uri_t setup_uri = {
        .uri = "/setup", .method = HTTP_POST, .handler = setup_handler
    };
    const httpd_uri_t redfish_config_uri = {
        .uri = "/api/redfish/config", .method = HTTP_POST,
        .handler = redfish_config_handler
    };
    const httpd_uri_t redfish_config_status_uri = {
        .uri = "/api/redfish/config", .method = HTTP_GET,
        .handler = redfish_config_status_handler
    };
    const httpd_uri_t redfish_clear_uri = {
        .uri = "/api/redfish/config", .method = HTTP_DELETE,
        .handler = redfish_clear_handler
    };
    const httpd_uri_t redfish_data_uri = {
        .uri = "/api/redfish/data", .method = HTTP_GET,
        .handler = redfish_data_handler
    };
    ESP_ERROR_CHECK(httpd_register_uri_handler(http_server, &index_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(http_server, &setup_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(http_server, &redfish_config_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(http_server, &redfish_config_status_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(http_server, &redfish_clear_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(http_server, &redfish_data_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(http_server, &info_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(http_server, &status_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(http_server, &log_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(http_server, &system_log_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(http_server, &ws_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(http_server, &ota_uri));
}

static bool tcp_login(int fd)
{
    if (!auth_configured) {
        send(fd, "SETUP REQUIRED\r\n", 16, 0);
        return false;
    }
    static const char prompt[] = "AUTH <passwort>\r\n";
    send(fd, prompt, sizeof(prompt) - 1, 0);

    char line[128] = {0};
    size_t used = 0;
    while (used < sizeof(line) - 1) {
        int n = recv(fd, line + used, 1, 0);
        if (n <= 0) {
            return false;
        }
        if (line[used] == '\r' || line[used] == '\n') {
            line[used] = '\0';
            break;
        }
        used++;
    }

    bool ok = strncmp(line, "AUTH ", 5) == 0 &&
              strlen(line + 5) <= AUTH_PASSWORD_MAX &&
              password_matches(line + 5);
    send(fd, ok ? "OK\r\n" : "DENIED\r\n", ok ? 4 : 8, 0);
    return ok;
}

static void tcp_server_task(void *arg)
{
    uint8_t data[IO_BUFFER_SIZE];
    for (;;) {
        int server = socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
        if (server < 0) {
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
        }
        int yes = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        struct sockaddr_in address = {
            .sin_family = AF_INET,
            .sin_port = htons(GATEWAY_TCP_PORT),
            .sin_addr.s_addr = htonl(INADDR_ANY)
        };
        if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0 ||
            listen(server, 1) != 0) {
            close(server);
            vTaskDelay(pdMS_TO_TICKS(1000));
            continue;
        }
        ESP_LOGI(TAG, "TCP-Bridge lauscht auf Port %d", GATEWAY_TCP_PORT);

        for (;;) {
            int fd = accept(server, NULL, NULL);
            if (fd < 0) {
                break;
            }
            struct timeval timeout = {.tv_sec = 30};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            if (!tcp_login(fd)) {
                close(fd);
                continue;
            }
            timeout.tv_sec = 1;
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            replace_client(&tcp_client, fd);

            int n;
            while ((n = recv(fd, data, sizeof(data), 0)) > 0 ||
                   (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))) {
                if (n > 0) {
                    write_uart(data, n);
                }
            }
            replace_client(&tcp_client, -1);
            close(fd);
        }
        close(server);
    }
}

static void uart_bridge_task(void *arg)
{
    uint8_t data[IO_BUFFER_SIZE];
    ESP_ERROR_CHECK(esp_task_wdt_add(NULL));

    for (;;) {
        int n = uart_read_bytes(UART_PORT, data, sizeof(data), pdMS_TO_TICKS(100));
        if (n > 0) {
            append_uart_log(data, n);
            int tcp_fd = tcp_client;
            if (tcp_fd >= 0 && send(tcp_fd, data, n, MSG_DONTWAIT) < 0 &&
                errno != EAGAIN && errno != EWOULDBLOCK) {
                replace_client(&tcp_client, -1);
            }

            int ws_fd = ws_client;
            if (ws_fd >= 0 && http_server) {
                httpd_ws_frame_t frame = {
                    .final = true, .fragmented = false,
                    .type = HTTPD_WS_TYPE_BINARY, .payload = data, .len = n
                };
                if (httpd_ws_send_frame_async(http_server, ws_fd, &frame) != ESP_OK) {
                    replace_client(&ws_client, -1);
                }
            }
        }
        ESP_ERROR_CHECK(esp_task_wdt_reset());
    }
}

static void reconnect_wifi(void *arg)
{
    esp_wifi_connect();
}

static void network_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        replace_client(&tcp_client, -1);
        replace_client(&ws_client, -1);
        esp_timer_stop(reconnect_timer);
        esp_timer_start_once(reconnect_timer, reconnect_delay_s * 1000000ULL);
        reconnect_delay_s = MIN(reconnect_delay_s * 2, 30U);
        ESP_LOGW(TAG, "WLAN getrennt; neuer Versuch in %u s", reconnect_delay_s / 2);
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *event = data;
        reconnect_delay_s = 1;
        ESP_LOGI(TAG, "WLAN verbunden: " IPSTR, IP2STR(&event->ip_info.ip));
    }
}

static void init_wifi(void)
{
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_t *netif = esp_netif_create_default_wifi_sta();
    ESP_ERROR_CHECK(esp_netif_set_hostname(netif, GATEWAY_HOSTNAME));

    wifi_init_config_t init = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&init));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                network_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                network_event, NULL));

    wifi_config_t wifi = {
        .sta = {
            .ssid = GATEWAY_WIFI_SSID,
            .password = GATEWAY_WIFI_PASSWORD,
            .threshold.authmode = WIFI_AUTH_WPA2_PSK,
            .failure_retry_cnt = 3
        }
    };
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wifi));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_ERROR_CHECK(esp_wifi_set_ps(WIFI_PS_NONE));
}

static void init_uart(void)
{
    const uart_config_t config = {
        .baud_rate = GATEWAY_UART_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT
    };
    ESP_ERROR_CHECK(uart_driver_install(UART_PORT, 2048, 0, 0, NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(UART_PORT, &config));
    ESP_ERROR_CHECK(uart_set_pin(UART_PORT, GATEWAY_UART_TX_GPIO,
                                 GATEWAY_UART_RX_GPIO,
                                 UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));
    ESP_ERROR_CHECK(gpio_set_pull_mode(GATEWAY_UART_RX_GPIO, GPIO_PULLUP_ONLY));
}

void app_main(void)
{
    console_vprintf = esp_log_set_vprintf(system_log_vprintf);

    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    } else {
        ESP_ERROR_CHECK(err);
    }

    uart_log_mutex = xSemaphoreCreateMutex();
    ESP_ERROR_CHECK(uart_log_mutex ? ESP_OK : ESP_ERR_NO_MEM);
    esp_fill_random(auth_cache_key, sizeof(auth_cache_key));
    load_auth();

    const esp_timer_create_args_t timer_args = {
        .callback = reconnect_wifi, .name = "wifi-reconnect"
    };
    ESP_ERROR_CHECK(esp_timer_create(&timer_args, &reconnect_timer));

    init_uart();
    init_wifi();
    start_http_server();
    xTaskCreate(uart_bridge_task, "uart-bridge", 4096, NULL, 10, NULL);
    xTaskCreate(tcp_server_task, "tcp-server", 4096, NULL, 8, NULL);
}
