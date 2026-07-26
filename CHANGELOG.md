# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [0.1.0] - 2026-07-26

### Added
- TCP networking — `tcp-connect`/`tcp-listen`/`tcp-accept`/`tcp-send`/
  `tcp-recv`/`tcp-close`, plus `tcp-listen-reuseport` and
  `reuseport-balances?` for SO_REUSEPORT multi-process listening
- TLS support — `tls-connect`/`tls-send`/`tls-recv`/`tls-close`,
  reactor-aware (WANT_READ/WANT_WRITE surfaced)
- Nonblocking primitives — `set-nonblocking`, `poll-read`, `poll-write`,
  `nb-accept`
- Reactor-integrated socket ports — `socket-port`, `tcp-connect-port`,
  `tcp-accept-port`
- C FFI shared library built via `make` (OpenSSL required for TLS)
- CI workflow for automated testing
