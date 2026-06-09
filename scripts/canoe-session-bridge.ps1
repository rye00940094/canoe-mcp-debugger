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
function GetTestEnvs($app){
  $out=@(); $envs=$app.Configuration.TestSetup.TestEnvironments
  for($i=1;$i -le $envs.Count;$i++){
    $e=$envs.Item($i); $mods=@()
    for($j=1;$j -le $e.TestModules.Count;$j++){
      $m=$e.TestModules.Item($j)
      $mods += [ordered]@{ index=$j; name=Safe{$m.Name}; fullName=Safe{$m.FullName}; path=Safe{$m.Path}; enabled=Safe{[bool]$m.Enabled}; verdict=Safe{[int]$m.Verdict}; startOnMeasurement=Safe{[bool]$m.StartOnMeasurementStart} }
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
    'start_measurement' { $a=GetApp $false; $to=if($req.timeoutMs){[int]$req.timeoutMs}else{30000}; if(-not $a.Measurement.Running){ $a.Measurement.Start() }; $ok=WaitUntil { $a.Measurement.Running } $to; return Json $ok @{ measurementRunning=[bool]$a.Measurement.Running; writeWindowTail=WriteTail $a 4000 } }
    'stop_measurement' { $a=GetApp $false; $to=if($req.timeoutMs){[int]$req.timeoutMs}else{30000}; if($a.Measurement.Running){ try{$a.Measurement.StopEx()}catch{$a.Measurement.Stop()} }; $ok=WaitUntil { -not $a.Measurement.Running } $to; return Json $ok @{ measurementRunning=[bool]$a.Measurement.Running; writeWindowTail=WriteTail $a 4000 } }
    'wait_measurement' { $a=GetApp $false; $to=if($req.timeoutMs){[int]$req.timeoutMs}else{30000}; $state=if($req.state){[string]$req.state}else{'started'}; if($state -eq 'stopped'){ $ok=WaitUntil { -not $a.Measurement.Running } $to } else { $ok=WaitUntil { $a.Measurement.Running } $to }; return Json $ok @{ measurementRunning=[bool]$a.Measurement.Running; targetState=$state; writeWindowTail=WriteTail $a 4000 } }
    'read_write_window' { $a=GetApp $false; $chars=if($req.maxChars){[int]$req.maxChars}elseif($req.tailLines){[int]$req.tailLines*120}else{12000}; return Json $true @{ text=WriteTail $a $chars } }
    'snapshot' { $a=GetApp $false; return Json $true @{ configuration=Safe{[string]$a.Configuration.FullName}; measurementRunning=Safe{[bool]$a.Measurement.Running}; testEnvironments=GetTestEnvs $a; writeWindowTail=WriteTail $a 12000 } }
    'start_test_module' { $a=GetApp $false; $sel=SelectModule $a $req; $m=$sel.module; $m.Enabled=$true; try{$m.StartOnMeasurementStart=$false}catch{}; $m.Start(); Start-Sleep -Milliseconds 300; return Json $true @{ environment=Safe{[string]$sel.env.Name}; module=Safe{[string]$m.Name}; fullName=Safe{[string]$m.FullName}; writeWindowTail=WriteTail $a 4000 } }
    'wait_test_module' { $a=GetApp $false; $sel=SelectModule $a $req; $m=$sel.module; $to=if($req.timeoutMs){[int]$req.timeoutMs}else{120000}; $sw=[Diagnostics.Stopwatch]::StartNew(); $running='unknown'; do{ Start-Sleep -Milliseconds 500; $running=Safe{[string]$m.Running} 'unknown'; $verdict=Safe{[string]$m.Verdict} 'unknown' }while(($running -eq 'True' -or $running -eq '1' -or $running -eq 'unknown') -and $sw.ElapsedMilliseconds -lt $to); $ok=($running -ne 'True' -and $running -ne '1' -and $running -ne 'unknown'); return Json $ok @{ module=Safe{[string]$m.Name}; running=$running; verdict=$verdict; elapsedMs=$sw.ElapsedMilliseconds; writeWindowTail=WriteTail $a 12000 } }
    default { return Json $false @{ error="unknown action: $($req.action)" } }
  }
}
while($line=[Console]::In.ReadLine()){
  try{ $req=$line|ConvertFrom-Json; InvokeRequest $req }catch{ Json $false @{ error=$_.Exception.Message; action=(Safe{[string]$req.action} '') } }
  [Console]::Out.Flush()
}
