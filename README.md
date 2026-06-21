# kaappi-net

Shared TCP/TLS networking library for [Kaappi Scheme](https://github.com/kaappi/kaappi).

Provides TCP client, TCP server, and TLS client operations. Used by
[kaappi-redis](https://github.com/kaappi/kaappi-redis),
[kaappi-http](https://github.com/kaappi/kaappi-http), and any other library
that needs network I/O.

## Build

Requires OpenSSL (for TLS support).

```bash
make                    # builds libkaappi_net.dylib (macOS) or .so (Linux)
```

## Usage

```bash
export DYLD_LIBRARY_PATH=/path/to/kaappi-net
kaappi --lib-path /path/to/kaappi-net/lib your-script.scm
```

```scheme
(import (kaappi net))

;; TCP client
(let ((fd (tcp-connect "example.com" 80)))
  (tcp-send fd (string->utf8 "GET / HTTP/1.0\r\n\r\n") 18)
  (let ((buf (make-bytevector 4096 0)))
    (tcp-recv fd buf 4096))
  (tcp-close fd))

;; TCP server
(let ((listen-fd (tcp-listen "0.0.0.0" 8080)))
  (let loop ()
    (let ((client-fd (tcp-accept listen-fd)))
      ;; handle client...
      (tcp-close client-fd)
      (loop))))

;; TLS client
(let ((ssl (tls-connect "api.github.com" 443)))
  (tls-send ssl request-bytes len)
  (tls-recv ssl buf len)
  (tls-close ssl))
```

## API

### TCP Client

| Procedure | Description |
|---|---|
| `(tcp-connect host port [timeout])` | Connect, returns fd |
| `(tcp-send fd buf len)` | Send bytes |
| `(tcp-recv fd buf len)` | Receive bytes |
| `(tcp-close fd)` | Close socket |

### TCP Server

| Procedure | Description |
|---|---|
| `(tcp-listen host port [backlog])` | Bind + listen, returns fd |
| `(tcp-accept listen-fd)` | Accept connection, returns client fd |

### TLS Client

| Procedure | Description |
|---|---|
| `(tls-connect host port [timeout])` | TLS handshake with SNI + cert verify |
| `(tls-send ssl buf len)` | Send over TLS |
| `(tls-recv ssl buf len)` | Receive over TLS |
| `(tls-close ssl)` | Shutdown TLS + close socket |

### Error

| Procedure | Description |
|---|---|
| `(tcp-last-error)` | Last errno value |

## Requirements

- [Kaappi](https://github.com/kaappi/kaappi) with `(kaappi ffi)` support
- OpenSSL 3.x (`brew install openssl` or `apt install libssl-dev`)

## License

MIT
