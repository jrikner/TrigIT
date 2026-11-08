// SPDX-License-Identifier: GPL-3.0-or-later

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <mmsystem.h>
#include <mmreg.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "CWindowsIO.h"

#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif

// Our own copies of the COM identifiers, so nothing depends on which import
// libraries define them.
static const CLSID kMMDeviceEnumerator = {0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}};
static const IID kIMMDeviceEnumerator = {0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}};
static const IID kIAudioClient = {0x1CB9AD4C, 0xDBFA, 0x4C32, {0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2}};
static const IID kIAudioCaptureClient = {0xC8ADBD64, 0xE71E, 0x48A0, {0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17}};
static const PROPERTYKEY kFriendlyName = {{0xA45C254E, 0xDF1C, 0x4EFD, {0x80, 0x20, 0x67, 0xD1, 0x46, 0xA8, 0x50, 0xE0}}, 14};
static const GUID kSubtypeFloat = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};
static const GUID kSubtypePCM = {0x00000001, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};

static void set_error(char *error, int32_t size, const char *format, long code) {
    if (error && size > 0) snprintf(error, (size_t)size, format, code);
}

// MARK: Clock and timer

double cwio_now(void) {
    static LARGE_INTEGER frequency;
    LARGE_INTEGER counter;
    if (frequency.QuadPart == 0) QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&counter);
    return (double)counter.QuadPart / (double)frequency.QuadPart;
}

static HANDLE tick_timer;

static const char *start_periodic(int32_t period_microseconds) {
    LARGE_INTEGER due;
    due.QuadPart = -(LONGLONG)period_microseconds * 10; // relative, in 100 ns units
    // Periodic, so the ticks don't drift by however long each tick's work took.
    LONG period_ms = period_microseconds / 1000 > 0 ? period_microseconds / 1000 : 1;
    return SetWaitableTimer(tick_timer, &due, period_ms, NULL, NULL, FALSE) ? "" : NULL;
}

const char *cwio_timer_open(int32_t period_microseconds) {
    timeBeginPeriod(1);
    // Windows 10 1803 and later: a timer that is not tied to the 15.6 ms system tick.
    tick_timer = CreateWaitableTimerExW(NULL, NULL, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    if (tick_timer && start_periodic(period_microseconds)) return "periodic high-resolution waitable timer, plus timeBeginPeriod(1)";
    tick_timer = CreateWaitableTimerExW(NULL, NULL, 0, TIMER_ALL_ACCESS);
    if (tick_timer && start_periodic(period_microseconds))
        return "periodic standard waitable timer with timeBeginPeriod(1) (no high-resolution timer on this Windows)";
    return NULL;
}

void cwio_timer_wait(void) {
    WaitForSingleObject(tick_timer, INFINITE);
}

// MARK: Ctrl+C

static void (*interrupt_handler)(void);

static BOOL WINAPI on_console_event(DWORD type) {
    if (interrupt_handler) interrupt_handler();
    // Closing the window ends the process when this returns: give the main
    // loop time to write the report first.
    if (type == CTRL_CLOSE_EVENT || type == CTRL_LOGOFF_EVENT || type == CTRL_SHUTDOWN_EVENT) Sleep(3000);
    return TRUE;
}

void cwio_on_interrupt(void (*handler)(void)) {
    interrupt_handler = handler;
    SetConsoleCtrlHandler(on_console_event, TRUE);
}

// MARK: UDP

static int winsock_ready(char *error, int32_t size) {
    static int ready;
    if (!ready) {
        WSADATA data;
        int code = WSAStartup(MAKEWORD(2, 2), &data);
        if (code != 0) {
            set_error(error, size, "WSAStartup failed (error %ld)", code);
            return 0;
        }
        ready = 1;
    }
    return 1;
}

int64_t cwio_udp_listen(uint16_t port, char *error, int32_t error_size) {
    if (!winsock_ready(error, error_size)) return -1;
    SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) {
        set_error(error, error_size, "socket failed (Winsock error %ld)", WSAGetLastError());
        return -1;
    }
    // Share the port with other Art-Net software on this PC, and take broadcasts.
    BOOL yes = TRUE;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char *)&yes, sizeof yes);
    setsockopt(s, SOL_SOCKET, SO_BROADCAST, (const char *)&yes, sizeof yes);
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(s, (struct sockaddr *)&address, sizeof address) == SOCKET_ERROR) {
        set_error(error, error_size, "could not open the UDP port (Winsock error %ld)", WSAGetLastError());
        closesocket(s);
        return -1;
    }
    return (int64_t)s;
}

int32_t cwio_udp_receive(int64_t socket, uint8_t *buffer, int32_t size) {
    int count = recv((SOCKET)socket, (char *)buffer, size, 0);
    return count == SOCKET_ERROR ? -1 : count;
}

int64_t cwio_udp_sender(char *error, int32_t error_size) {
    if (!winsock_ready(error, error_size)) return -1;
    SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) {
        set_error(error, error_size, "socket failed (Winsock error %ld)", WSAGetLastError());
        return -1;
    }
    BOOL yes = TRUE;
    setsockopt(s, SOL_SOCKET, SO_BROADCAST, (const char *)&yes, sizeof yes);
    return (int64_t)s;
}

int32_t cwio_udp_resolve(const char *host, uint32_t *address) {
    struct addrinfo hints, *result = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (!winsock_ready(NULL, 0) || getaddrinfo(host, NULL, &hints, &result) != 0 || !result) return -1;
    *address = ((struct sockaddr_in *)result->ai_addr)->sin_addr.s_addr;
    freeaddrinfo(result);
    return 0;
}

int32_t cwio_udp_send(int64_t socket, uint32_t address, uint16_t port, const uint8_t *bytes, int32_t count) {
    struct sockaddr_in to;
    memset(&to, 0, sizeof to);
    to.sin_family = AF_INET;
    to.sin_port = htons(port);
    to.sin_addr.s_addr = address;
    int sent = sendto((SOCKET)socket, (const char *)bytes, count, 0, (struct sockaddr *)&to, sizeof to);
    return sent == SOCKET_ERROR ? WSAGetLastError() : 0;
}

// MARK: Audio

static void utf8(const wchar_t *wide, char *out, int32_t size) {
    if (!out || size <= 0) return;
    out[0] = 0;
    if (wide) WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, size, NULL, NULL);
}

static int contains_ignoring_case(const char *text, const char *part) {
    size_t n = strlen(part);
    for (; *text; text++) {
        size_t i = 0;
        while (i < n && text[i] && tolower((unsigned char)text[i]) == tolower((unsigned char)part[i])) i++;
        if (i == n) return 1;
    }
    return n == 0;
}

static void device_name(IMMDevice *device, char *out, int32_t size) {
    IPropertyStore *store = NULL;
    out[0] = 0;
    if (FAILED(IMMDevice_OpenPropertyStore(device, STGM_READ, &store))) return;
    PROPVARIANT value;
    PropVariantInit(&value);
    if (SUCCEEDED(IPropertyStore_GetValue(store, &kFriendlyName, &value)) && value.vt == VT_LPWSTR) utf8(value.pwszVal, out, size);
    PropVariantClear(&value);
    IPropertyStore_Release(store);
}

static int device_is(IMMDevice *device, const wchar_t *id) {
    LPWSTR own = NULL;
    int same = id && SUCCEEDED(IMMDevice_GetId(device, &own)) && wcscmp(own, id) == 0;
    CoTaskMemFree(own);
    return same;
}

static IMMDeviceEnumerator *enumerator(char *error, int32_t size) {
    IMMDeviceEnumerator *result = NULL;
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
        set_error(error, size, "CoInitializeEx failed (0x%08lx)", hr);
        return NULL;
    }
    hr = CoCreateInstance(&kMMDeviceEnumerator, NULL, CLSCTX_ALL, &kIMMDeviceEnumerator, (void **)&result);
    if (FAILED(hr)) set_error(error, size, "could not reach Windows audio (0x%08lx)", hr);
    return result;
}

/// Finds the input to use; `name_contains` empty means the default one.
static IMMDevice *find_input(const char *name_contains, cwio_audio_device_fn each, void *context, char *error, int32_t size) {
    IMMDeviceEnumerator *devices = enumerator(error, size);
    if (!devices) return NULL;
    IMMDevice *found = NULL, *fallback = NULL;
    LPWSTR default_id = NULL;
    if (SUCCEEDED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(devices, eCapture, eConsole, &fallback))) {
        IMMDevice_GetId(fallback, &default_id);
    }
    IMMDeviceCollection *collection = NULL;
    UINT count = 0;
    if (SUCCEEDED(IMMDeviceEnumerator_EnumAudioEndpoints(devices, eCapture, DEVICE_STATE_ACTIVE, &collection))) {
        IMMDeviceCollection_GetCount(collection, &count);
        for (UINT i = 0; i < count; i++) {
            IMMDevice *device = NULL;
            if (FAILED(IMMDeviceCollection_Item(collection, i, &device))) continue;
            char name[256];
            device_name(device, name, sizeof name);
            if (each) each(context, name, device_is(device, default_id));
            if (!each && !found && name_contains && name_contains[0] && contains_ignoring_case(name, name_contains)) {
                found = device;
            } else {
                IMMDevice_Release(device);
            }
        }
        IMMDeviceCollection_Release(collection);
    }
    CoTaskMemFree(default_id);
    IMMDeviceEnumerator_Release(devices);
    if (each) {
        if (fallback) IMMDevice_Release(fallback);
        return NULL;
    }
    if (name_contains && name_contains[0]) {
        if (fallback) IMMDevice_Release(fallback);
        if (!found) snprintf(error, (size_t)size, "no audio input has \"%s\" in its name (see --list-devices)", name_contains);
        return found;
    }
    if (!fallback) set_error(error, size, "there is no default recording device", 0);
    return fallback;
}

int32_t cwio_audio_list(cwio_audio_device_fn each, void *context, char *error, int32_t error_size) {
    if (error && error_size > 0) error[0] = 0;
    find_input(NULL, each, context, error, error_size);
    return error && error[0] ? -1 : 0;
}

enum sample_format { SAMPLES_FLOAT32, SAMPLES_INT16, SAMPLES_INT32 };

static struct {
    IAudioClient *client;
    IAudioCaptureClient *capture;
    HANDLE ready;
    int channels;
    int channel;
    enum sample_format format;
    double rate;
    cwio_audio_samples_fn each;
    void *context;
    float *block;
    UINT32 block_size;
} capture;

static DWORD WINAPI capture_thread(LPVOID unused) {
    (void)unused;
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    DWORD task = 0;
    AvSetMmThreadCharacteristicsW(L"Pro Audio", &task);
    for (;;) {
        if (WaitForSingleObject(capture.ready, 2000) != WAIT_OBJECT_0) continue;
        double arrival = cwio_now();
        UINT32 frames = 0;
        while (SUCCEEDED(IAudioCaptureClient_GetNextPacketSize(capture.capture, &frames)) && frames > 0) {
            BYTE *data = NULL;
            DWORD flags = 0;
            UINT64 position = 0, qpc = 0;
            if (FAILED(IAudioCaptureClient_GetBuffer(capture.capture, &data, &frames, &flags, &position, &qpc))) break;
            if (frames > capture.block_size) {
                free(capture.block);
                capture.block = malloc(sizeof(float) * frames);
                capture.block_size = capture.block ? frames : 0;
            }
            if (capture.block) {
                for (UINT32 i = 0; i < frames; i++) {
                    size_t at = (size_t)i * capture.channels + capture.channel;
                    float sample = 0;
                    if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT)) {
                        switch (capture.format) {
                        case SAMPLES_FLOAT32: sample = ((const float *)data)[at]; break;
                        case SAMPLES_INT16: sample = ((const int16_t *)data)[at] / 32768.0f; break;
                        case SAMPLES_INT32: sample = (float)(((const int32_t *)data)[at] / 2147483648.0); break;
                        }
                    }
                    capture.block[i] = sample;
                }
                // qpc is the QueryPerformanceCounter time of the first frame, in 100 ns
                // units, unless WASAPI flags it unreliable.
                int timestamp_ok = qpc && !(flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR);
                double first = timestamp_ok ? (double)qpc / 1e7 : arrival - frames / capture.rate;
                capture.each(capture.context, capture.block, (int32_t)frames, capture.rate, first, arrival);
            }
            IAudioCaptureClient_ReleaseBuffer(capture.capture, frames);
        }
    }
    return 0;
}

int32_t cwio_audio_start(const char *name_contains, int32_t channel, cwio_audio_samples_fn each, void *context,
                         char *device_name_out, int32_t device_name_size, double *sample_rate, double *buffer_period,
                         char *error, int32_t error_size) {
    IMMDevice *device = find_input(name_contains, NULL, NULL, error, error_size);
    if (!device) return -1;
    device_name(device, device_name_out, device_name_size);

    HRESULT hr = IMMDevice_Activate(device, &kIAudioClient, CLSCTX_ALL, NULL, (void **)&capture.client);
    IMMDevice_Release(device);
    if (FAILED(hr)) {
        set_error(error, error_size, "could not open the audio input (0x%08lx)", hr);
        return -1;
    }
    WAVEFORMATEX *format = NULL;
    if (FAILED(hr = IAudioClient_GetMixFormat(capture.client, &format))) {
        set_error(error, error_size, "could not read the input's format (0x%08lx)", hr);
        return -1;
    }
    int is_float = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    int is_pcm = format->wFormatTag == WAVE_FORMAT_PCM;
    if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        const WAVEFORMATEXTENSIBLE *extensible = (const WAVEFORMATEXTENSIBLE *)format;
        is_float = memcmp(&extensible->SubFormat, &kSubtypeFloat, sizeof(GUID)) == 0;
        is_pcm = memcmp(&extensible->SubFormat, &kSubtypePCM, sizeof(GUID)) == 0;
    }
    if (is_float && format->wBitsPerSample == 32) capture.format = SAMPLES_FLOAT32;
    else if (is_pcm && format->wBitsPerSample == 16) capture.format = SAMPLES_INT16;
    else if (is_pcm && format->wBitsPerSample == 32) capture.format = SAMPLES_INT32;
    else {
        set_error(error, error_size, "unsupported audio format (%ld bits)", format->wBitsPerSample);
        CoTaskMemFree(format);
        return -1;
    }
    capture.channels = format->nChannels;
    capture.rate = format->nSamplesPerSec;
    if (channel < 0 || channel >= capture.channels) {
        set_error(error, error_size, "the input has only %ld channel(s)", capture.channels);
        CoTaskMemFree(format);
        return -1;
    }
    capture.channel = channel;
    capture.each = each;
    capture.context = context;

    REFERENCE_TIME default_period = 0, minimum_period = 0;
    IAudioClient_GetDevicePeriod(capture.client, &default_period, &minimum_period);
    hr = IAudioClient_Initialize(capture.client, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, default_period, 0, format, NULL);
    CoTaskMemFree(format);
    if (FAILED(hr)) {
        set_error(error, error_size, "could not start the audio input (0x%08lx)", hr);
        return -1;
    }
    capture.ready = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (FAILED(hr = IAudioClient_SetEventHandle(capture.client, capture.ready)) ||
        FAILED(hr = IAudioClient_GetService(capture.client, &kIAudioCaptureClient, (void **)&capture.capture)) ||
        FAILED(hr = IAudioClient_Start(capture.client))) {
        set_error(error, error_size, "could not start the audio input (0x%08lx)", hr);
        return -1;
    }
    *sample_rate = capture.rate;
    *buffer_period = default_period / 1e7;
    if (!CreateThread(NULL, 0, capture_thread, NULL, 0, NULL)) {
        set_error(error, error_size, "could not start the capture thread (error %ld)", (long)GetLastError());
        return -1;
    }
    return 0;
}
