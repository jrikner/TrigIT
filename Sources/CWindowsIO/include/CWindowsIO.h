// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Windows calls the spike needs, behind plain C types: the clock, the tick
// timer, Ctrl+C, UDP over Winsock and WASAPI audio capture. Error messages are
// written into caller-supplied buffers.

#pragma once
#include <stdint.h>

/// Seconds on the QueryPerformanceCounter clock. WASAPI's capture timestamps
/// are on the same clock.
double cwio_now(void);

/// Calls timeBeginPeriod(1) and creates the tick timer, preferring a
/// high-resolution waitable timer. Returns a description of what it got, or
/// NULL on failure.
const char *cwio_timer_open(int32_t period_microseconds);
/// Sleeps one tick period.
void cwio_timer_wait(void);

/// Calls `handler` on Ctrl+C, Ctrl+Break or closing the console window.
void cwio_on_interrupt(void (*handler)(void));

/// A UDP socket bound to `port` on every interface, receiving broadcasts.
/// Returns -1 on failure.
int64_t cwio_udp_listen(uint16_t port, char *error, int32_t error_size);
/// Blocks for the next datagram; returns its length, or -1 on error.
int32_t cwio_udp_receive(int64_t socket, uint8_t *buffer, int32_t size);
/// A UDP socket for sending. Returns -1 on failure.
int64_t cwio_udp_sender(char *error, int32_t error_size);
/// Resolves an IPv4 host name or address. Returns 0 on success.
int32_t cwio_udp_resolve(const char *host, uint32_t *address);
/// Sends one datagram. Returns 0, or the Winsock error code.
int32_t cwio_udp_send(int64_t socket, uint32_t address, uint16_t port, const uint8_t *bytes, int32_t count);

/// A TCP listener on 127.0.0.1 only, for the browser UI. Returns -1 on failure.
int64_t cwio_tcp_listen(uint16_t port, char *error, int32_t error_size);
/// Blocks for the next connection, with 2 s send and receive timeouts. Returns -1 on error.
int64_t cwio_tcp_accept(int64_t listener);
/// Reads up to the blank line ending an HTTP request's headers, or until `size`.
/// Returns the bytes read, or -1.
int32_t cwio_tcp_read_request(int64_t connection, uint8_t *buffer, int32_t size);
/// Sends all of `bytes`, then closes the connection.
void cwio_tcp_send_and_close(int64_t connection, const uint8_t *bytes, int32_t count);
/// Opens a URL in the default browser.
void cwio_open_url(const char *url);

/// Lists the active audio inputs. Returns 0, or -1 with `error` filled in.
typedef void (*cwio_audio_device_fn)(void *context, const char *name, int32_t is_default);
int32_t cwio_audio_list(cwio_audio_device_fn each, void *context, char *error, int32_t error_size);

/// Called on the capture thread with one channel's samples (-1...1), the time
/// its first sample was recorded and the time the block reached the app.
typedef void (*cwio_audio_samples_fn)(void *context, const float *samples, int32_t count, double sample_rate,
                                      double first_sample_time, double arrival_time);
/// Starts capturing `channel` (0-based) of the first active input whose name
/// contains `name_contains` (any case), or of the default input when it is
/// empty. Fills in the device's name, sample rate and buffer period.
/// Returns 0, or -1 with `error` filled in.
int32_t cwio_audio_start(const char *name_contains, int32_t channel, cwio_audio_samples_fn each, void *context,
                         char *device_name, int32_t device_name_size, double *sample_rate, double *buffer_period,
                         char *error, int32_t error_size);
