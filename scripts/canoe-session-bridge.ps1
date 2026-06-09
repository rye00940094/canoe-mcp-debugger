param()
$ErrorActionPreference = 'Continue'
$app = $null

function Json($ok, $data=@{}) {
  $o = [ordered]@{ ok = [bool]$ok }
  foreach($k in $data.Keys){ $o[$k] = $data[$k] }
  $o | ConvertTo-Json -Depth 20 -Compress
}
function Safe([scriptblock]$b, $d=$null){ try { & $b } catch { $d } }
function GetApp([bool]$create=$false){
  if($script:app){ return $script:app }
  try { $script:app = [Runtime.InteropServices.Marshal]::GetActiveObject('CANoe.Application'); return $script:app } catch {}
  if($create){ $script:app = New-Object -ComObject CANoe.Application; return $script:app }
  throw 'CANoe.Application is not attached in this MCP session; call canoe_open_configuration first'
}
function WriteTail($app, [int]$chars=12000){
  $t = Safe { [string]$app.UI.Write.Text } ''
  if($t.Length -gt $chars){ return $t.Substring($t.Length-$chars) }
  return $t
}
function WaitUntil([scriptblock]$cond, [int]$timeoutMs){
  $sw=[Diagnostics.Stopwatch]::StartNew()
  while($sw.ElapsedMilliseconds -lt $timeoutMs){ if(& $cond){ return $true }; Start-Sleep -Milliseconds 200 }
  return (& $cond)
}
function SetSv($app,$ns,$var,$val){ $v=$app.System.Namespaces.Item($ns).Variables.Item($var); $v.Value=$val; return $v.Value }
function InvokeComMethod($target, [string]$methodName, [object[]]$arguments = @()){
  return $target.GetType().InvokeMember($methodName, [Reflection.BindingFlags]::InvokeMethod, $null, $target, $arguments)
}
function GetWriteWindowDelta([string]$before, [string]$after) {
  if([string]::IsNullOrEmpty($after)) { return '' }
  if([string]::IsNullOrEmpty($before)) { return $after }
  if($after.StartsWith($before)) { return $after.Substring($before.Length) }
  return $after
}

function HasTestcaseWriteEvidence([string]$deltaTail) {
  if([string]::IsNullOrWhiteSpace($deltaTail)) { return $false }
  return ($deltaTail -match '\[AGC_[A-Z0-9_]+\]') -or ($deltaTail -match 'TC_[A-Za-z0-9_]+') -or ($deltaTail -match 'TestCase|testcase')
}

function GetModuleEvidence($app, $module) {
  $evidence = [ordered]@{
    name = Safe { [string]$module.Name }
    fullName = Safe { [string]$module.FullName }
    path = Safe { [string]$module.Path }
    enabled = Safe { [bool]$module.Enabled }
    running = Safe { [string]$module.Running }
    verdict = Safe { [string]$module.Verdict }
    writeWindowTail = WriteTail $app 12000
  }
  try {
    $report = $module.Report
    $evidence.reportFullName = Safe { [string]$report.FullName }
    $evidence.reportLastWrittenFullName = Safe { [string]$report.LastWrittenFullName }
    $evidence.reportAutoNumbering = Safe { [bool]$report.AutoNumbering }
    $evidence.reportFormat = Safe { [string]$report.ReportFormat }
  } catch {
    $evidence.reportError = $_.Exception.Message
  }
  return $evidence
}

function EnsureModuleEnabled($app, $module) {
  $enabled = Safe { [bool]$module.Enabled } $false
  if($enabled){ return [ordered]@{ changed = $false; enabled = $true } }
  if($app.Measurement.Running){
    throw 'module is disabled while measurement is running; enable it before starting measurement or use a dedicated enable step'
  }
  $module.Enabled = $true
  return [ordered]@{ changed = $true; enabled = Safe { [bool]$module.Enabled } $true }
}

function StartTestModuleStrict($app, $module, [int]$timeoutMs = 60000) {
  $beforeVerdict = Safe { [string]$module.Verdict } ''
  $beforeRunning = Safe { [string]$module.Running } ''
  $beforeReport = Safe { [string]$module.Report.LastWrittenFullName } ''
  $beforeWriteTail = WriteTail $app 12000
  try {
    $module.Start()
  } catch {
    return [ordered]@{
      ok = $false
      error = $_.Exception.Message
      beforeVerdict = $beforeVerdict
      beforeRunning = $beforeRunning
      beforeReportLastWrittenFullName = $beforeReport
      evidence = GetModuleEvidence $app $module
    }
  }

  $sw=[Diagnostics.Stopwatch]::StartNew()
  $startObserved = $false
  $stopObserved = $false
  $lastRunning = ''
  $lastVerdict = ''
  $lastReport = ''
  do {
    Start-Sleep -Milliseconds 250
    $lastRunning = Safe { [string]$module.Running } ''
    $lastVerdict = Safe { [string]$module.Verdict } ''
    $lastReport = Safe { [string]$module.Report.LastWrittenFullName } ''
    if($lastRunning -eq 'True' -or $lastRunning -eq '1'){ $startObserved = $true }
    if($startObserved -and ($lastRunning -eq '' -or $lastRunning -eq 'False' -or $lastRunning -eq '0')){ $stopObserved = $true; break }
  } while($sw.ElapsedMilliseconds -lt $timeoutMs)

  $evidence = GetModuleEvidence $app $module
  $writeDelta = GetWriteWindowDelta $beforeWriteTail ([string]$evidence.writeWindowTail)
  $writeEvidence = HasTestcaseWriteEvidence $writeDelta
  $reportEvidence = -not [string]::IsNullOrWhiteSpace([string]$evidence.reportLastWrittenFullName)
  $verdictChanged = ($beforeVerdict -ne $lastVerdict) -and -not [string]::IsNullOrWhiteSpace($lastVerdict)
  $ran = $startObserved -or $stopObserved -or $writeEvidence -or $reportEvidence -or $verdictChanged

  return [ordered]@{
    ok = [bool]$ran
    ran = [bool]$ran
    startObserved = $startObserved
    stopObserved = $stopObserved
    beforeVerdict = $beforeVerdict
    afterVerdict = $lastVerdict
    beforeRunning = $beforeRunning
    afterRunning = $lastRunning
    beforeReportLastWrittenFullName = $beforeReport
    afterReportLastWrittenFullName = $lastReport
    elapsedMs = $sw.ElapsedMilliseconds
    writeDelta = $writeDelta
    writeEvidence = $writeEvidence
    reportEvidence = $reportEvidence
    verdictChanged = $verdictChanged
    evidence = $evidence
    error = if(-not $ran){ 'test module did not produce execution evidence' } else { $null }
  }
}

function WaitTestModuleStrict($app, $module, [int]$timeoutMs = 120000) {
  $sw=[Diagnostics.Stopwatch]::StartNew()
  $seenStart = $false
  $lastRunning = ''
  $lastVerdict = ''
  $lastReport = ''
  $beforeWriteTail = WriteTail $app 12000
  do {
    Start-Sleep -Milliseconds 500
    $lastRunning = Safe { [string]$module.Running } ''
    $lastVerdict = Safe { [string]$module.Verdict } ''
    $lastReport = Safe { [string]$module.Report.LastWrittenFullName } ''
    if($lastRunning -eq 'True' -or $lastRunning -eq '1'){ $seenStart = $true }
    if($seenStart -and ($lastRunning -eq '' -or $lastRunning -eq 'False' -or $lastRunning -eq '0')){ break }
  } while($sw.ElapsedMilliseconds -lt $timeoutMs)

  $evidence = GetModuleEvidence $app $module
  $writeDelta = GetWriteWindowDelta $beforeWriteTail ([string]$evidence.writeWindowTail)
  $writeEvidence = HasTestcaseWriteEvidence $writeDelta
  $reportEvidence = -not [string]::IsNullOrWhiteSpace([string]$evidence.reportLastWrittenFullName)
  $verdictChanged = -not [string]::IsNullOrWhiteSpace($lastVerdict) -and ($lastVerdict -ne '0')
  $ok = $seenStart -or $reportEvidence -or $verdictChanged -or $writeEvidence

  return [ordered]@{
    ok = [bool]$ok
    seenStart = $seenStart
    running = $lastRunning
    verdict = $lastVerdict
    elapsedMs = $sw.ElapsedMilliseconds
    writeDelta = $writeDelta
    writeEvidence = $writeEvidence
    reportEvidence = $reportEvidence
    verdictChanged = $verdictChanged
    evidence = $evidence
    error = if(-not $ok){ 'test module did not show execution evidence' } else { $null }
  }
}

function GetStartOnMeasurementValue($module) {
  $value = Safe { [bool]$module.StartOnMeasurement } $null
  if($null -ne $value) { return $value }
  return Safe { [bool]$module.StartOnMeasurementStart } $null
}

function SetStartOnMeasurementValue($module, [bool]$value) {
  $done = $false
  try { $module.StartOnMeasurement = $value; $done = $true } catch {}
  if(-not $done) {
    try { $module.StartOnMeasurementStart = $value; $done = $true } catch {}
  }
  if(-not $done) { throw 'could not set StartOnMeasurement property' }
}

function GetTestEnvs($app){
  $out=@(); $envs=$app.Configuration.TestSetup.TestEnvironments
  for($i=1;$i -le $envs.Count;$i++){
    $e=$envs.Item($i); $mods=@()
    for($j=1;$j -le $e.TestModules.Count;$j++){
      $m=$e.TestModules.Item($j)
      $mods += [ordered]@{ index=$j; name=Safe{$m.Name}; fullName=Safe{$m.FullName}; path=Safe{$m.Path}; enabled=Safe{[bool]$m.Enabled}; verdict=Safe{[int]$m.Verdict}; startOnMeasurement=GetStartOnMeasurementValue $m }
    }
    $out += [ordered]@{ index=$i; name=Safe{$e.Name}; fullName=Safe{$e.FullName}; modules=$mods }
  }
  return $out
}
function NormalizePathText($value){
  if($null -eq $value){ return '' }
  return ([string]$value).Replace('/','\\').Trim().ToLowerInvariant()
}
function SelectModule($app,$req){
  $envs=$app.Configuration.TestSetup.TestEnvironments
  $envName=[string]$req.environment; $modName=[string]$req.module
  $envNameNorm=NormalizePathText $envName; $modNameNorm=NormalizePathText $modName
  $envIndex = if($req.environmentIndex){ [int]$req.environmentIndex } else { 0 }
  $modIndex = if($req.moduleIndex){ [int]$req.moduleIndex } else { 0 }
  $matches=@()
  for($i=1;$i -le $envs.Count;$i++){
    $e=$envs.Item($i)
    if($envIndex -gt 0 -and $i -ne $envIndex){ continue }
    $eName=[string]$e.Name; $eFull=[string]$e.FullName; $eFullNorm=NormalizePathText $eFull
    if($envName -and $envName -ne '' -and $eName -ne $envName -and $eFull -ne $envName -and $eFullNorm -ne $envNameNorm){ continue }
    for($j=1;$j -le $e.TestModules.Count;$j++){
      $m=$e.TestModules.Item($j)
      if($modIndex -gt 0 -and $j -ne $modIndex){ continue }
      $mName=[string]$m.Name; $mFull=[string]$m.FullName; $mPath=[string]$m.Path
      $mFullNorm=NormalizePathText $mFull; $mPathNorm=NormalizePathText $mPath
      $mFile=Split-Path -Leaf $mFull
      if($modName -and $modName -ne '' -and $mName -ne $modName -and $mFull -ne $modName -and $mPath -ne $modName -and $mFullNorm -ne $modNameNorm -and $mPathNorm -ne $modNameNorm -and $mFile -ne $modName){ continue }
      $matches += [pscustomobject]@{ env=$e; module=$m; envIndex=$i; moduleIndex=$j }
    }
  }
  if($matches.Count -ne 1){ throw "test module selection matched $($matches.Count) modules" }
  return $matches[0]
}

function SelectTestEnvironment($app, $req) {
  $envs = $app.Configuration.TestSetup.TestEnvironments
  $envName = [string]$req.environment
  $envNameNorm = NormalizePathText $envName
  $envIndex = if($req.environmentIndex){ [int]$req.environmentIndex } else { 0 }
  $matches=@()
  for($i=1;$i -le $envs.Count;$i++){
    $e=$envs.Item($i)
    if($envIndex -gt 0 -and $i -ne $envIndex){ continue }
    $eName=[string]$e.Name; $eFull=[string]$e.FullName; $eFullNorm=NormalizePathText $eFull
    if($envName -and $envName -ne '' -and $eName -ne $envName -and $eFull -ne $envName -and $eFullNorm -ne $envNameNorm){ continue }
    $matches += [pscustomobject]@{ env=$e; envIndex=$i }
  }
  if($matches.Count -ne 1){ throw "test environment selection matched $($matches.Count) environments" }
  return $matches[0]
}
function InvokeRequest($req){
  switch([string]$req.action){
    'open_configuration' {
      $a=GetApp $true
      $a.Visible=$true
      $a.Open([string]$req.cfgPath, [bool]$req.autoSave, [bool]$req.promptUser)
      return Json $true @{ configuration=Safe{[string]$a.Configuration.FullName}; measurementRunning=Safe{[bool]$a.Measurement.Running}; writeWindowTail=WriteTail $a 1200 }
    }
    'status' {
      $attached=$false; $err=$null; try{ $a=GetApp $false; $attached=$true }catch{ $err=$_.Exception.Message; $a=$null }
      $procs=@(Get-Process CANoe64,RuntimeKernel -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name=$_.ProcessName; id=$_.Id; path=$_.Path; responding=$_.Responding; mainWindowTitle=$_.MainWindowTitle } })
      $d=@{ attached=$attached; processes=$procs }
      if($attached){ $d.configuration=Safe{[string]$a.Configuration.FullName}; $d.measurementRunning=Safe{[bool]$a.Measurement.Running}; $d.writeWindowTail=WriteTail $a 1200 } else { $d.error=$err }
      return Json $true $d
    }
    'set_system_variable' { $a=GetApp $false; $val=SetSv $a ([string]$req.namespace) ([string]$req.variable) $req.value; return Json $true @{ namespace=$req.namespace; variable=$req.variable; value=$val } }
    'get_system_variable' { $a=GetApp $false; $v=$a.System.Namespaces.Item([string]$req.namespace).Variables.Item([string]$req.variable).Value; return Json $true @{ namespace=$req.namespace; variable=$req.variable; value=$v } }
    'compile_capl' { $a=GetApp $false; InvokeComMethod $a.CAPL 'Compile' | Out-Null; return Json $true @{ writeWindowTail=WriteTail $a 4000 } }
    'get_signal' { $a=GetApp $false; $bus=if($req.bus){[string]$req.bus}else{'CAN'}; $channel=if($req.channel){[int]$req.channel}else{1}; $sig=$a.Bus($bus).GetSignal($channel, [string]$req.message, [string]$req.signal); return Json $true @{ bus=$bus; channel=$channel; message=$req.message; signal=$req.signal; value=$sig.Value } }
    'call_capl_function' { $a=GetApp $false; $fn=$a.CAPL.GetFunction([string]$req.functionName); $caplArgs=@(); if($req.args){ foreach($item in $req.args){ $caplArgs += $item } }; if($caplArgs.Count -gt 10){ throw 'CAPLFunction.Call supports at most 10 parameters' }; $ret=InvokeComMethod $fn 'Call' $caplArgs; return Json $true @{ functionName=$req.functionName; returnValue=$ret; writeWindowTail=WriteTail $a 4000 } }
    'list_test_modules' { $a=GetApp $false; return Json $true @{ testEnvironments=GetTestEnvs $a } }
    'set_test_module_enabled' { $a=GetApp $false; $sel=SelectModule $a $req; if($a.Measurement.Running){ throw 'cannot change Enabled during measurement' }; $target = if($null -ne $req.enabled){ [bool]$req.enabled } else { $true }; $sel.module.Enabled = $target; return Json $true @{ environment=Safe{[string]$sel.env.Name}; module=Safe{[string]$sel.module.Name}; fullName=Safe{[string]$sel.module.FullName}; enabled=Safe{[bool]$sel.module.Enabled}; startOnMeasurement=GetStartOnMeasurementValue $sel.module } }
    'start_measurement' { $a=GetApp $false; $to=if($req.timeoutMs){[int]$req.timeoutMs}else{30000}; if(-not $a.Measurement.Running){ $a.Measurement.Start() }; $ok=WaitUntil { $a.Measurement.Running } $to; return Json $ok @{ measurementRunning=[bool]$a.Measurement.Running; writeWindowTail=WriteTail $a 4000 } }
    'stop_measurement' { $a=GetApp $false; $to=if($req.timeoutMs){[int]$req.timeoutMs}else{30000}; if($a.Measurement.Running){ try{$a.Measurement.StopEx()}catch{$a.Measurement.Stop()} }; $ok=WaitUntil { -not $a.Measurement.Running } $to; return Json $ok @{ measurementRunning=[bool]$a.Measurement.Running; writeWindowTail=WriteTail $a 4000 } }
    'wait_measurement' { $a=GetApp $false; $to=if($req.timeoutMs){[int]$req.timeoutMs}else{30000}; $state=if($req.state){[string]$req.state}else{'started'}; if($state -eq 'stopped'){ $ok=WaitUntil { -not $a.Measurement.Running } $to } else { $ok=WaitUntil { $a.Measurement.Running } $to }; return Json $ok @{ measurementRunning=[bool]$a.Measurement.Running; targetState=$state; writeWindowTail=WriteTail $a 4000 } }
    'read_write_window' { $a=GetApp $false; $chars=if($req.maxChars){[int]$req.maxChars}elseif($req.tailLines){[int]$req.tailLines*120}else{12000}; return Json $true @{ text=WriteTail $a $chars } }
    'snapshot' { $a=GetApp $false; return Json $true @{ configuration=Safe{[string]$a.Configuration.FullName}; measurementRunning=Safe{[bool]$a.Measurement.Running}; testEnvironments=GetTestEnvs $a; writeWindowTail=WriteTail $a 12000 } }
    'start_test_module' { $a=GetApp $false; $sel=SelectModule $a $req; $m=$sel.module; $enableResult = EnsureModuleEnabled $a $m; if(-not $a.Measurement.Running){ try{ SetStartOnMeasurementValue $m $false }catch{} }; $to=if($req.timeoutMs){[int]$req.timeoutMs}else{60000}; $r=StartTestModuleStrict $a $m $to; return Json ([bool]$r.ok) ([ordered]@{ environment=Safe{[string]$sel.env.Name}; module=Safe{[string]$m.Name}; fullName=Safe{[string]$m.FullName}; enableResult=$enableResult; startOnMeasurement=GetStartOnMeasurementValue $m; startResult=$r; writeWindowTail=WriteTail $a 4000 }) }
    'wait_test_module' { $a=GetApp $false; $sel=SelectModule $a $req; $m=$sel.module; $to=if($req.timeoutMs){[int]$req.timeoutMs}else{120000}; $r=WaitTestModuleStrict $a $m $to; return Json ([bool]$r.ok) ([ordered]@{ module=Safe{[string]$m.Name}; environment=Safe{[string]$sel.env.Name}; waitResult=$r; running=$r.running; verdict=$r.verdict; elapsedMs=$r.elapsedMs; writeWindowTail=WriteTail $a 12000 }) }
    'execute_test_environment' { $a=GetApp $false; $sel=SelectTestEnvironment $a $req; if(-not $a.Measurement.Running){ throw 'measurement must be running before ExecuteAll()' }; $beforeWriteTail = WriteTail $a 12000; $sel.env.ExecuteAll(); Start-Sleep -Milliseconds 500; $writeTail = WriteTail $a 12000; $writeDelta = GetWriteWindowDelta $beforeWriteTail $writeTail; return Json $true @{ environment=Safe{[string]$sel.env.Name}; environmentIndex=$sel.envIndex; writeDelta=$writeDelta; writeWindowTail=$writeTail } }
    default { return Json $false @{ error="unknown action: $($req.action)" } }
  }
}
while($line=[Console]::In.ReadLine()){
  try{ $req=$line|ConvertFrom-Json; InvokeRequest $req }catch{ Json $false @{ error=$_.Exception.Message; action=(Safe{[string]$req.action} '') } }
  [Console]::Out.Flush()
}
