param(
  [Parameter(Mandatory = $true)]
  [string]$RequestJson
)

$ErrorActionPreference = 'Stop'

$EventHelperPath = Join-Path $PSScriptRoot 'canoe-event-wait.vbs'
$CscriptPath = Join-Path $env:SystemRoot 'System32\\cscript.exe'

function ConvertTo-JsonSafe($value) {
  $value | ConvertTo-Json -Depth 12 -Compress
}

function Result($ok, $data = @{}, $message = $null) {
  $body = [ordered]@{ ok = [bool]$ok }
  if ($message) { $body.message = $message }
  foreach ($key in $data.Keys) { $body[$key] = $data[$key] }
  ConvertTo-JsonSafe $body
}

function Fail($message, $extra = @{}) {
  $data = [ordered]@{ error = $message }
  foreach ($key in $extra.Keys) { $data[$key] = $extra[$key] }
  Result $false $data
}

function Get-SafeValue([scriptblock]$getter, $default = $null) {
  try {
    return & $getter
  } catch {
    return $default
  }
}

function Get-CANoeApp($create = $true) {
  try {
    return [Runtime.InteropServices.Marshal]::GetActiveObject('CANoe.Application')
  } catch {
    if (-not $create) { throw }
    return New-Object -ComObject CANoe.Application
  }
}

function Get-WriteText($app, [int]$tailLines = 120) {
  try { $text = [string]$app.UI.Write.Text } catch { return '' }
  if ($tailLines -le 0 -or [string]::IsNullOrEmpty($text)) { return $text }
  $lines = $text -split "`r?`n"
  if ($lines.Count -le $tailLines) { return $text }
  return ($lines | Select-Object -Last $tailLines) -join "`n"
}

function Get-ProcessInfo {
  @(Get-Process CANoe64, CANoe32, RuntimeKernel -ErrorAction SilentlyContinue | ForEach-Object {
    $processPath = $null
    try { $processPath = $_.Path } catch {}
    [ordered]@{
      name = $_.ProcessName
      id = $_.Id
      responding = $_.Responding
      path = $processPath
      mainWindowTitle = $_.MainWindowTitle
    }
  })
}

function Get-StatusData {
  $data = [ordered]@{ processes = Get-ProcessInfo }
  try {
    $app = Get-CANoeApp $false
    $data.attached = $true
    $data.visible = $app.Visible
    $data.configuration = try { $app.Configuration.FullName } catch { $null }
    $data.measurementRunning = try { [bool]$app.Measurement.Running } catch { $false }
  } catch {
    $data.attached = $false
    $data.error = $_.Exception.Message
  }
  return $data
}

function Wait-Until([scriptblock]$predicate, [int]$timeoutMs) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  do {
    if (& $predicate) { return $true }
    Start-Sleep -Milliseconds 250
  } while ([DateTime]::UtcNow -lt $deadline)
  return $false
}

function Invoke-ComMethod($target, [string]$methodName, [object[]]$arguments = @()) {
  return $target.GetType().InvokeMember(
    $methodName,
    [Reflection.BindingFlags]::InvokeMethod,
    $null,
    $target,
    $arguments
  )
}

function Invoke-EventWaitHelper([string[]]$arguments) {
  if (-not (Test-Path -LiteralPath $EventHelperPath)) {
    throw "Event helper not found: $EventHelperPath"
  }

  $output = & $CscriptPath '//nologo' $EventHelperPath @arguments 2>&1
  $exitCode = $LASTEXITCODE
  $text = ($output | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) {
    throw 'Event helper returned no output'
  }

  try {
    $parsed = $text | ConvertFrom-Json
  } catch {
    throw "Event helper returned non-JSON stdout: $text"
  }

  if ($exitCode -ne 0 -and $parsed.ok) {
    throw "Event helper exited with code $exitCode despite ok=true"
  }

  return $parsed
}

function Add-EventSelectorArguments([System.Collections.Generic.List[string]]$arguments, $request) {
  if ($null -ne $request.environment -and [string]$request.environment -ne '') {
    $arguments.Add("environment=$($request.environment)")
  }
  if ($null -ne $request.module -and [string]$request.module -ne '') {
    $arguments.Add("module=$($request.module)")
  }
  if ($null -ne $request.environmentIndex) {
    $arguments.Add("environmentIndex=$([int]$request.environmentIndex)")
  }
  if ($null -ne $request.moduleIndex) {
    $arguments.Add("moduleIndex=$([int]$request.moduleIndex)")
  }
}

function Get-RequestInt($request, [string]$propertyName, [int]$defaultValue) {
  $property = $request.PSObject.Properties[$propertyName]
  if ($null -eq $property -or $null -eq $property.Value -or [string]$property.Value -eq '') {
    return $defaultValue
  }
  return [int]$property.Value
}

function Get-RequestString($request, [string]$propertyName, [string]$defaultValue) {
  $property = $request.PSObject.Properties[$propertyName]
  if ($null -eq $property -or $null -eq $property.Value -or [string]$property.Value -eq '') {
    return $defaultValue
  }
  return [string]$property.Value
}

function Get-TestModuleSummary($module, $environment = $null) {
  $summary = [ordered]@{
    name = Get-SafeValue { $module.Name }
    fullName = Get-SafeValue { $module.FullName }
    path = Get-SafeValue { $module.Path }
    enabled = Get-SafeValue { [bool]$module.Enabled }
    startOnMeasurement = Get-SafeValue { [bool]$module.StartOnMeasurement }
    verdict = Get-SafeValue { [int]$module.Verdict }
  }
  if ($environment) {
    $summary.environment = Get-SafeValue { $environment.Name }
    $summary.environmentFullName = Get-SafeValue { $environment.FullName }
  }
  return $summary
}

function Get-TestEnvironments($app) {
  $items = @()
  $envs = $app.Configuration.TestSetup.TestEnvironments
  for ($envIndex = 1; $envIndex -le $envs.Count; $envIndex++) {
    $env = $envs.Item($envIndex)
    $envName = $null
    $envFullName = $null
    try { $envName = $env.Name } catch {}
    try { $envFullName = $env.FullName } catch {}
    $modules = @()
    for ($moduleIndex = 1; $moduleIndex -le $env.TestModules.Count; $moduleIndex++) {
      $module = $env.TestModules.Item($moduleIndex)
      $moduleName = $null
      $moduleFullName = $null
      $moduleEnabled = $null
      $moduleStartOnMeasurement = $null
      try { $moduleName = $module.Name } catch {}
      try { $moduleFullName = $module.FullName } catch {}
      try { $moduleEnabled = [bool]$module.Enabled } catch {}
      try { $moduleStartOnMeasurement = [bool]$module.StartOnMeasurement } catch {}
      $modules += [ordered]@{
        index = $moduleIndex
        name = $moduleName
        fullName = $moduleFullName
        enabled = $moduleEnabled
        startOnMeasurement = $moduleStartOnMeasurement
      }
    }
    $items += [ordered]@{
      index = $envIndex
      name = $envName
      fullName = $envFullName
      modules = $modules
    }
  }
  return $items
}

function Select-TestModule($app, $request) {
  $envs = $app.Configuration.TestSetup.TestEnvironments
  if ($request.environmentIndex) {
    $env = $envs.Item([int]$request.environmentIndex)
  } elseif ($request.environment) {
    $env = $null
    for ($i = 1; $i -le $envs.Count; $i++) {
      $candidate = $envs.Item($i)
      if ($candidate.Name -eq $request.environment -or $candidate.FullName -eq $request.environment) { $env = $candidate; break }
    }
    if (-not $env) { throw "Test environment not found: $($request.environment)" }
  } else {
    $env = $null
  }

  if ($env) {
    if ($request.moduleIndex) { return $env.TestModules.Item([int]$request.moduleIndex) }
    for ($i = 1; $i -le $env.TestModules.Count; $i++) {
      $module = $env.TestModules.Item($i)
      if ($module.Name -eq $request.module -or $module.FullName -eq $request.module) { return $module }
    }
    throw "Test module not found in selected environment: $($request.module)"
  }

  $matches = @()
  for ($ei = 1; $ei -le $envs.Count; $ei++) {
    $candidateEnv = $envs.Item($ei)
    for ($mi = 1; $mi -le $candidateEnv.TestModules.Count; $mi++) {
      $module = $candidateEnv.TestModules.Item($mi)
      if (($request.module -and ($module.Name -eq $request.module -or $module.FullName -eq $request.module)) -or ($request.moduleIndex -and $mi -eq [int]$request.moduleIndex)) {
        $matches += $module
      }
    }
  }
  if ($matches.Count -eq 1) { return $matches[0] }
  if ($matches.Count -gt 1) { throw "Multiple test modules matched; provide environment/environmentIndex" }
  throw "Test module not found"
}

try {
  $request = $RequestJson | ConvertFrom-Json
  switch ($request.action) {
    'status' {
      Result $true (Get-StatusData)
    }
    'open_configuration' {
      if (-not (Test-Path -LiteralPath $request.cfgPath)) { throw "Configuration not found: $($request.cfgPath)" }
      $app = Get-CANoeApp $true
      $app.Visible = [bool]$request.visible
      $app.Open([string]$request.cfgPath, [bool]$request.autoSave, [bool]$request.promptUser)
      Result $true ([ordered]@{ status = Get-StatusData; writeWindowTail = Get-WriteText $app 80 }) 'configuration opened'
    }
    'compile_capl' {
      $app = Get-CANoeApp $false
      Invoke-ComMethod $app.CAPL 'Compile'
      Result $true ([ordered]@{ writeWindowTail = Get-WriteText $app 120 }) 'CAPL compile requested'
    }
    'start_measurement' {
      $app = Get-CANoeApp $false
      if (-not $app.Measurement.Running) {
        $args = [System.Collections.Generic.List[string]]::new()
        $args.Add('mode=measurement-start')
        $args.Add("timeoutMs=$(Get-RequestInt $request 'timeoutMs' 30000)")
        $eventResult = Invoke-EventWaitHelper $args
      } else {
        $eventResult = [pscustomobject]@{ ok = $true; event = 'measurement-already-running'; measurementRunning = $true }
      }
      $running = [bool]$app.Measurement.Running
      Result $running ([ordered]@{ measurementRunning = $running; eventResult = $eventResult; writeWindowTail = Get-WriteText $app 120 }) $(if ($running) { 'measurement started' } else { 'measurement did not start before timeout' })
    }
    'stop_measurement' {
      $app = Get-CANoeApp $false
      if ($app.Measurement.Running) {
        $args = [System.Collections.Generic.List[string]]::new()
        $args.Add('mode=measurement-stop')
        $args.Add("timeoutMs=$(Get-RequestInt $request 'timeoutMs' 30000)")
        $eventResult = Invoke-EventWaitHelper $args
      } else {
        $eventResult = [pscustomobject]@{ ok = $true; event = 'measurement-already-stopped'; measurementRunning = $false }
      }
      $stopped = -not [bool]$app.Measurement.Running
      Result $stopped ([ordered]@{ measurementRunning = [bool]$app.Measurement.Running; eventResult = $eventResult; writeWindowTail = Get-WriteText $app 120 }) $(if ($stopped) { 'measurement stopped' } else { 'measurement did not stop before timeout' })
    }
    'read_write_window' {
      $app = Get-CANoeApp $false
      Result $true ([ordered]@{ text = Get-WriteText $app ([int]$request.tailLines) })
    }
    'get_system_variable' {
      $app = Get-CANoeApp $false
      $var = $app.System.Namespaces.Item([string]$request.namespace).Variables.Item([string]$request.variable)
      Result $true ([ordered]@{ namespace = $request.namespace; variable = $request.variable; value = $var.Value })
    }
    'set_system_variable' {
      $app = Get-CANoeApp $false
      $var = $app.System.Namespaces.Item([string]$request.namespace).Variables.Item([string]$request.variable)
      $var.Value = $request.value
      Result $true ([ordered]@{ namespace = $request.namespace; variable = $request.variable; value = $var.Value })
    }
    'get_signal' {
      $app = Get-CANoeApp $false
      $signal = $app.Bus([string]$request.bus).GetSignal([int]$request.channel, [string]$request.message, [string]$request.signal)
      Result $true ([ordered]@{ bus = $request.bus; channel = $request.channel; message = $request.message; signal = $request.signal; value = $signal.Value })
    }
    'call_capl_function' {
      $app = Get-CANoeApp $false
      $fn = $app.CAPL.GetFunction([string]$request.functionName)
      $args = @($request.args)
      if ($args.Count -gt 10) { throw 'CAPLFunction.Call supports at most 10 parameters' }
      $returnValue = Invoke-ComMethod $fn 'Call' $args
      Result $true ([ordered]@{ functionName = $request.functionName; returnValue = $returnValue; writeWindowTail = Get-WriteText $app 80 })
    }
    'list_test_modules' {
      $app = Get-CANoeApp $false
      Result $true ([ordered]@{ testEnvironments = Get-TestEnvironments $app })
    }
    'start_test_module' {
      $app = Get-CANoeApp $false
      $module = Select-TestModule $app $request
      $args = [System.Collections.Generic.List[string]]::new()
      $args.Add('mode=testmodule-start')
      $args.Add("timeoutMs=$(Get-RequestInt $request 'timeoutMs' 30000)")
      Add-EventSelectorArguments $args $request
      $eventResult = Invoke-EventWaitHelper $args
      Result ([bool]$eventResult.ok) ([ordered]@{ module = Get-TestModuleSummary $module; eventResult = $eventResult; writeWindowTail = Get-WriteText $app 120 }) 'test module start requested'
    }
    'wait_test_module' {
      $app = Get-CANoeApp $false
      $module = Select-TestModule $app $request
      $args = [System.Collections.Generic.List[string]]::new()
      $args.Add('mode=testmodule-wait-stop')
      $args.Add("timeoutMs=$(Get-RequestInt $request 'timeoutMs' 120000)")
      Add-EventSelectorArguments $args $request
      $eventResult = Invoke-EventWaitHelper $args
      Result ([bool]$eventResult.ok) ([ordered]@{ module = Get-TestModuleSummary $module; eventResult = $eventResult; writeWindowTail = Get-WriteText $app 120 }) 'test module wait completed'
    }
    'wait_measurement' {
      $app = Get-CANoeApp $false
      $targetState = Get-RequestString $request 'state' 'started'
      $mode = if ($targetState -eq 'stopped') { 'measurement-stop' } else { 'measurement-start' }
      $args = [System.Collections.Generic.List[string]]::new()
      $args.Add("mode=$mode")
      $args.Add("timeoutMs=$(Get-RequestInt $request 'timeoutMs' 30000)")
      $eventResult = Invoke-EventWaitHelper $args
      Result ([bool]$eventResult.ok) ([ordered]@{ measurementRunning = [bool]$app.Measurement.Running; eventResult = $eventResult; writeWindowTail = Get-WriteText $app 120 }) 'measurement wait completed'
    }
    'snapshot' {
      $app = $null
      try { $app = Get-CANoeApp $false } catch {}
      $data = [ordered]@{ status = Get-StatusData }
      if ($app) {
        $data.writeWindowTail = Get-WriteText $app ([int]$request.tailLines)
        try { $data.testEnvironments = Get-TestEnvironments $app } catch { $data.testModuleError = $_.Exception.Message }
      }
      Result $true $data
    }
    default { throw "Unknown action: $($request.action)" }
  }
} catch {
  Fail $_.Exception.Message ([ordered]@{ action = try { $request.action } catch { $null } })
}
