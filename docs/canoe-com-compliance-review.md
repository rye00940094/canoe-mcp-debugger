# CANoe COM Compliance Review

This review checks the MCP bridge against CANoe Help documents from the local MinerU MCP server, collection `CANoe_Help`.

## Sources consulted

- `CANoe_Help/canoe/20-pdf/an-and-1-117-canalyzer-canoe-as-a-com-server.md`
- `CANoe_Help/canoe/10-chm/canoecanalyzer/topics/cominterface/methods/commethodopen.md`
- `CANoe_Help/canoe/10-chm/canoecanalyzer/topics/cominterface/methods/commethodstart.md`
- `CANoe_Help/canoe/10-chm/canoecanalyzer/topics/cominterface/methods/commethodstopex.md`
- `CANoe_Help/canoe/10-chm/canoecanalyzer/topics/cominterface/methods/commethodcall.md`
- `CANoe_Help/canoe/10-chm/canoecanalyzer/topics/cominterface/methods/commethodgetsignal.md`
- `CANoe_Help/canoe/10-chm/canoecanalyzer/topics/cominterface/objects/comobjectcapl.md`

## Findings

### Compliant areas

- `Application.Open(path, autoSave, promptUser)` matches CANoe COM syntax.
- `Measurement.Start()` is valid for starting measurement.
- Test module `Start()` is valid, and the MCP starts measurement separately before module execution.
- `Application.Bus("CAN").GetSignal(channel, message, signal).Value` matches CANoe COM `GetSignal` syntax.
- System variable access through `Application.System.Namespaces.Item(...).Variables.Item(...).Value` follows the documented object model used by CANoe COM examples.
- `Application.CAPL.GetFunction(name)` is the correct access path for user-defined CAPL functions.

### Fixed during review

- CAPL compile now calls `CAPL.Compile()` without a dummy `$null` argument. CANoe Help documents `Compile` as a no-argument method.
- Measurement stop now uses `Measurement.StopEx()` instead of deprecated `Measurement.Stop()`. CANoe 12 Help says `StopEx` replaces deprecated measurement `Stop` and corresponds to clicking the Stop button.
- CAPL function calls now expand arguments as COM method parameters instead of passing the whole array as one argument. CANoe Help documents `CAPLFunction.Call([p1..p10])`; the bridge now enforces the 10-parameter limit.

### Remaining caveats

- CANoe Help recommends waiting for `OnStart` events to be sure measurement/test module startup actually happened. This MCP currently polls `Measurement.Running`, which is acceptable for a minimal interactive bridge but less strict than event-driven COM automation.
- CAPL return values are only documented as available for CAPL programs configured in Measurement Setup, and only integer return values are supported.
- CAPL COM access only reaches user-defined CAPL functions; built-in CAPL functions are not exposed through `GetFunction`.
- COM server version binding still depends on the registered CANoe COM server unless CANoe is launched explicitly beforehand.

## Recommendation

The MCP is broadly aligned with CANoe COM automation rules after the fixes above. For production-grade interactive debugging, the next improvement should be an event-aware bridge using `WScript.ConnectObject` or a C# COM event sink so `Measurement.OnStart`, `Measurement.OnStop`, and test module events can be reported back to the agent.
