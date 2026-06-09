# CANoe MCP Debugger

Interactive MCP server for operating and debugging Vector CANoe projects through COM.

## What it does

This server exposes CANoe as MCP tools so an agent can debug step-by-step instead of running one fixed script. It keeps CANoe controllable through repeated MCP calls:

- open a CANoe configuration
- compile CAPL
- start/stop measurement
- read the Write Window
- read/write system variables
- read bus signals
- call CAPL functions
- list and start test modules
- wait for measurement and test module COM events
- collect a compact debug snapshot

## Requirements

- Windows with Vector CANoe installed and COM registered
- Node.js 20+
- PowerShell 5+
- Hermes Agent or another MCP client

This project targets local Windows execution. On this machine Hermes terminal uses Git Bash/MSYS, but the MCP server itself calls `powershell.exe` directly.

## Install

```bash
npm install
npm test
```

## Run as a stdio MCP server

```bash
npm start
```

Hermes config example:

```yaml
mcp_servers:
  canoe:
    command: "node"
    args: ["D:/BYD_AGC/canoe-mcp-debugger/src/server.js"]
    timeout: 180
    connect_timeout: 60
```

Restart Hermes after adding the config. Tools will appear with names similar to `mcp_canoe_canoe_status`.

## Tools

| Tool | Purpose |
| --- | --- |
| `canoe_status` | CANoe COM/process/config/measurement status |
| `canoe_open_configuration` | Open `.cfg` / CANoe configuration |
| `canoe_compile_capl` | Compile CAPL |
| `canoe_start_measurement` | Start measurement |
| `canoe_stop_measurement` | Stop measurement |
| `canoe_read_write_window` | Read Write Window tail |
| `canoe_get_system_variable` | Read system variable |
| `canoe_set_system_variable` | Write system variable |
| `canoe_get_signal` | Read signal value |
| `canoe_call_capl_function` | Call exposed CAPL function |
| `canoe_list_test_modules` | Enumerate test modules |
| `canoe_start_test_module` | Start selected test module and wait for `TSTestModule.OnStart` |
| `canoe_wait_measurement` | Wait for `Measurement.OnStart` / `Measurement.OnStop` |
| `canoe_wait_test_module` | Wait for `TSTestModule.OnStop` and return stop reason / verdict when available |
| `canoe_snapshot` | Status + Write Window + test module snapshot |

## Typical interactive flow

1. `canoe_open_configuration` with the project `.cfg` path.
2. `canoe_compile_capl`.
3. `canoe_start_measurement` or `canoe_wait_measurement` to synchronize with measurement state.
4. `canoe_read_write_window` to inspect startup errors.
5. `canoe_set_system_variable` / `canoe_call_capl_function` to drive the setup.
6. `canoe_start_test_module` to run one module.
7. `canoe_wait_test_module` to wait for completion and collect stop reason / verdict.
8. `canoe_snapshot` after failures to decide the next action.

## CANoe notes

- COM controls external CANoe automation; arbitrary CAN transmission should normally go through CAPL functions or signal/sysvar interaction.
- CAPL function handles must be valid in the loaded configuration; some workflows require preparation during `Measurement.OnInit`.
- Measurement and test-module synchronization uses a VBScript helper with `WScript.ConnectObject`, matching CANoe COM examples for `Measurement.OnStart`, `Measurement.OnStop`, `TSTestModule.OnStart`, `TSTestModule.OnStop`, and `TSTestModule.OnVerdictFail`.
- .NET modules execute in `RuntimeKernel.exe`; attach there for managed-code breakpoints.
- If multiple CANoe versions are installed, register/launch the intended CANoe version before using COM.

## Environment variables

- `CANOE_MCP_POWERSHELL`: override PowerShell executable path. Defaults to `powershell.exe`.

## Smoke test

`npm test` starts the MCP server through the SDK stdio client and verifies tool discovery. It does not require CANoe to be installed.
