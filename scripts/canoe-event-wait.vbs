' CANoe COM event-aware wait helper for cscript.exe
Option Explicit

Dim args, opts
Set args = WScript.Arguments
Set opts = CreateObject("Scripting.Dictionary")

Dim i, token, pos, key, value
For i = 0 To args.Count - 1
  token = CStr(args.Item(i))
  pos = InStr(token, "=")
  If pos > 0 Then
    key = LCase(Left(token, pos - 1))
    value = Mid(token, pos + 1)
    opts(key) = value
  End If
Next

Dim mode
mode = GetOpt("mode", "")
If mode = "" Then
  EmitError "missing mode"
End If

Dim timeoutMs
timeoutMs = CLng(GetOpt("timeoutms", "30000"))

Dim app
On Error Resume Next
Set app = GetObject(, "CANoe.Application")
If Err.Number <> 0 Then
  EmitError "CANoe.Application is not running: " & Err.Description
End If
On Error GoTo 0

Dim measurement
Set measurement = app.Measurement

Dim measurementStarted, measurementStopped
measurementStarted = False
measurementStopped = False

Dim moduleStartRequested, moduleStarted, moduleStopped, verdictFailed, stopReason
moduleStartRequested = False
moduleStarted = False
moduleStopped = False
verdictFailed = False
stopReason = -1

Dim targetModule, targetEnv
Set targetModule = Nothing
Set targetEnv = Nothing
If Left(mode, 10) = "testmodule" Then
  Set targetModule = ResolveTestModule(app, opts, targetEnv)
  If targetModule Is Nothing Then
    EmitError "test module not found"
  End If
End If

WScript.ConnectObject measurement, "Meas_"
If Not (targetModule Is Nothing) Then
  WScript.ConnectObject targetModule, "TM_"
End If

Select Case mode
  Case "measurement-start"
    If measurement.Running Then
      measurementStarted = True
    Else
      measurement.Start
    End If
  Case "measurement-stop"
    If measurement.Running Then
      measurement.StopEx
    Else
      measurementStopped = True
    End If
  Case "testmodule-start"
    If Not measurement.Running Then
      measurement.Start
    Else
      measurementStarted = True
    End If
  Case "testmodule-wait-stop"
    If Not measurement.Running Then
      EmitError "measurement is not running"
    End If
  Case Else
    EmitError "unknown mode: " & mode
End Select

Dim startedAt
startedAt = Timer
Do
  Select Case mode
    Case "measurement-start"
      If measurementStarted Or measurement.Running Then
        EmitMeasurementResult True, "measurement-started"
      End If
    Case "measurement-stop"
      If measurementStopped Or (Not measurement.Running) Then
        EmitMeasurementResult True, "measurement-stopped"
      End If
    Case "testmodule-start"
      If (Not measurementStarted) And measurement.Running Then measurementStarted = True
      If measurementStarted And (Not moduleStartRequested) Then
        targetModule.Start
        moduleStartRequested = True
      End If
      If moduleStarted Then
        EmitTestModuleResult True, "testmodule-started", False
      End If
      If measurementStopped Then
        EmitTestModuleResult False, "measurement-stopped-before-testmodule-start", False
      End If
    Case "testmodule-wait-stop"
      If moduleStopped Then
        EmitTestModuleResult True, "testmodule-stopped", True
      End If
      If measurementStopped Then
        EmitTestModuleResult False, "measurement-stopped-before-testmodule-stop", True
      End If
  End Select

  If ElapsedMs(startedAt) >= timeoutMs Then
    Select Case mode
      Case "measurement-start"
        EmitMeasurementResult False, "timeout"
      Case "measurement-stop"
        EmitMeasurementResult False, "timeout"
      Case "testmodule-start"
        EmitTestModuleResult False, "timeout", False
      Case "testmodule-wait-stop"
        EmitTestModuleResult False, "timeout", True
    End Select
  End If

  WScript.Sleep 100
Loop

Sub Meas_OnStart()
  measurementStarted = True
End Sub

Sub Meas_OnStop()
  measurementStopped = True
End Sub

Sub TM_OnStart()
  moduleStarted = True
End Sub

Sub TM_OnStop(reason)
  moduleStopped = True
  stopReason = reason
End Sub

Sub TM_OnVerdictFail()
  verdictFailed = True
End Sub

Function ResolveTestModule(appObj, byRef options, byRef envOut)
  Dim envs, envObj, moduleObj
  Set envs = appObj.Configuration.TestSetup.TestEnvironments

  Dim envIndex, moduleIndex, envName, moduleName
  envIndex = GetOpt("environmentindex", "")
  moduleIndex = GetOpt("moduleindex", "")
  envName = GetOpt("environment", "")
  moduleName = GetOpt("module", "")

  If envIndex <> "" Then
    Set envObj = envs.Item(CInt(envIndex))
  ElseIf envName <> "" Then
    Set envObj = FindEnvironment(envs, envName)
  Else
    Set envObj = Nothing
  End If

  If Not (envObj Is Nothing) Then
    If moduleIndex <> "" Then
      Set moduleObj = envObj.TestModules.Item(CInt(moduleIndex))
    Else
      Set moduleObj = FindModule(envObj.TestModules, moduleName)
    End If
    Set envOut = envObj
    Set ResolveTestModule = moduleObj
    Exit Function
  End If

  Dim ei, mi, matches, candidateEnv, candidateModule
  matches = 0
  For ei = 1 To envs.Count
    Set candidateEnv = envs.Item(ei)
    For mi = 1 To candidateEnv.TestModules.Count
      Set candidateModule = candidateEnv.TestModules.Item(mi)
      If moduleName <> "" Then
        If StrComp(CStr(candidateModule.Name), moduleName, vbTextCompare) = 0 Or StrComp(CStr(candidateModule.FullName), moduleName, vbTextCompare) = 0 Then
          matches = matches + 1
          Set moduleObj = candidateModule
          Set envObj = candidateEnv
        End If
      ElseIf moduleIndex <> "" And mi = CInt(moduleIndex) Then
        matches = matches + 1
        Set moduleObj = candidateModule
        Set envObj = candidateEnv
      End If
    Next
  Next

  If matches = 1 Then
    Set envOut = envObj
    Set ResolveTestModule = moduleObj
  Else
    Set ResolveTestModule = Nothing
  End If
End Function

Function FindEnvironment(envs, envName)
  Dim i, envObj
  Set FindEnvironment = Nothing
  For i = 1 To envs.Count
    Set envObj = envs.Item(i)
    If StrComp(CStr(envObj.Name), envName, vbTextCompare) = 0 Or StrComp(CStr(envObj.FullName), envName, vbTextCompare) = 0 Then
      Set FindEnvironment = envObj
      Exit Function
    End If
  Next
End Function

Function FindModule(modules, moduleName)
  Dim i, moduleObj
  Set FindModule = Nothing
  For i = 1 To modules.Count
    Set moduleObj = modules.Item(i)
    If moduleName = "" Then
      Set FindModule = moduleObj
      Exit Function
    End If
    If StrComp(CStr(moduleObj.Name), moduleName, vbTextCompare) = 0 Or StrComp(CStr(moduleObj.FullName), moduleName, vbTextCompare) = 0 Then
      Set FindModule = moduleObj
      Exit Function
    End If
  Next
End Function

Function GetOpt(name, defaultValue)
  If opts.Exists(LCase(name)) Then
    GetOpt = opts(LCase(name))
  Else
    GetOpt = defaultValue
  End If
End Function

Function ElapsedMs(started)
  Dim nowv, diff
  nowv = Timer
  diff = nowv - started
  If diff < 0 Then diff = diff + 86400
  ElapsedMs = CLng(diff * 1000)
End Function

Sub EmitMeasurementResult(ok, eventName)
  Dim json
  json = "{" & _
    Quote("ok") & ":" & LCase(CStr(ok)) & "," & _
    Quote("event") & ":" & Quote(eventName) & "," & _
    Quote("measurementRunning") & ":" & LCase(CStr(CBool(measurement.Running))) & _
    "}"
  WScript.Echo json
  If ok Then WScript.Quit 0 Else WScript.Quit 1
End Sub

Sub EmitTestModuleResult(ok, eventName, includeVerdict)
  Dim json, verdictValue
  verdictValue = "null"
  If includeVerdict Then
    On Error Resume Next
    verdictValue = CStr(targetModule.Verdict)
    If Err.Number <> 0 Then
      verdictValue = "null"
      Err.Clear
    End If
    On Error GoTo 0
  End If

  json = "{" & _
    Quote("ok") & ":" & LCase(CStr(ok)) & "," & _
    Quote("event") & ":" & Quote(eventName) & "," & _
    Quote("measurementRunning") & ":" & LCase(CStr(CBool(measurement.Running))) & "," & _
    Quote("moduleStarted") & ":" & LCase(CStr(moduleStarted)) & "," & _
    Quote("moduleStopped") & ":" & LCase(CStr(moduleStopped)) & "," & _
    Quote("verdictFailed") & ":" & LCase(CStr(verdictFailed)) & "," & _
    Quote("stopReason") & ":" & stopReason & "," & _
    Quote("moduleName") & ":" & Quote(CStr(targetModule.Name)) & "," & _
    Quote("environmentName") & ":" & Quote(CStr(targetEnv.Name)) & "," & _
    Quote("verdict") & ":" & verdictValue & _
    "}"
  WScript.Echo json
  If ok Then WScript.Quit 0 Else WScript.Quit 1
End Sub

Sub EmitError(message)
  WScript.Echo "{" & Quote("ok") & ":false," & Quote("error") & ":" & Quote(message) & "}"
  WScript.Quit 1
End Sub

Function Quote(text)
  Quote = Chr(34) & EscapeJson(CStr(text)) & Chr(34)
End Function

Function EscapeJson(text)
  Dim s
  s = text
  s = Replace(s, "\", "\\")
  s = Replace(s, Chr(34), "\" & Chr(34))
  s = Replace(s, vbCrLf, "\n")
  s = Replace(s, vbCr, "\n")
  s = Replace(s, vbLf, "\n")
  EscapeJson = s
End Function
