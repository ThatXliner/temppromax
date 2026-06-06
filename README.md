# temppromax

`temppromax` is a macOS command-line temperature monitor for Apple Silicon Macs. It reads PMU temperature sensors through the HID Event System and does not require sudo, launchd, or any privileged helper.

## Build

```sh
swift build
```

The debug binary is written to:

```sh
.build/debug/temppromax
```

## Usage

```sh
temppromax [--die] [--json] [--watch[=N] | -w N] [--no-color]
```

Options:

- `--die`: only show die temperature sensors.
- `--json`: print JSON.
- `--watch[=N]` or `-w N`: refresh in place every `N` seconds.
- `--no-color`: disable ANSI color.

If no PMU sensors are available, the tool exits with:

```txt
Not an Apple Silicon Mac or sensors unavailable
```
