# Genuine native control supervisor; Windows execution is mandatory.
# No process instrumentation, mocks, forced signals or quota bypass.
param([Parameter(Mandatory=$true)][string]$SourceRoot,
      [Parameter(Mandatory=$true)][string]$SourceRevision,
      [Parameter(Mandatory=$true)][string]$CompilerReceipt,
      [Parameter(Mandatory=$true)][string]$OwnedPathHelper)
$ErrorActionPreference='Stop'
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') { throw 'Native Windows x64 required' }
if ($SourceRevision -cnotmatch '^[0-9a-f]{40}$') { throw 'Exact published source revision required' }
function Regular([string]$path) {
  if(-not [IO.Path]::IsPathFullyQualified($path)){throw 'Relative principal refused'}
  $item=Get-Item -LiteralPath $path -Force
  if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Nonregular principal refused'}
  [ordered]@{path=$item.FullName;length=$item.Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$helperBefore=Regular $OwnedPathHelper
# Built-in deny-write/delete stream supplies authority before helper evaluation.
$helperStream=[IO.File]::Open($OwnedPathHelper,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
$captured=[IO.MemoryStream]::new()
try{$helperStream.CopyTo($captured);$helperBytes=$captured.ToArray()}finally{$captured.Dispose()}
$helperSHA=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($helperBytes)).ToLowerInvariant()
if($helperSHA -cne '10a232fbec8a9c8a16797aa21bc298b914ad7d3721a3201019347d3e7c1f16db' -or $helperSHA -cne $helperBefore.sha256){throw 'Held immutable helper bytes refused'}
. ([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString($helperBytes)))
$helperHold=[NativePythonOwnedPath]::new($OwnedPathHelper,$false)
$helperId=$helperHold.Identity()
$source=Assert-SafeDirectory $SourceRoot
$sourceHold=[NativePythonOwnedPath]::new($source,$false);$sourceId=$sourceHold.Identity()
$receiptBefore=Regular $CompilerReceipt
$receiptHold=[NativePythonOwnedPath]::new($CompilerReceipt,$false);$receiptId=$receiptHold.Identity()
$receiptBytes=[IO.File]::ReadAllBytes($CompilerReceipt)
$receiptBufferSHA=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($receiptBytes)).ToLowerInvariant()
if($receiptBufferSHA -cne $receiptBefore.sha256){throw 'Held acquisition receipt bytes changed before parse'}
$receipt=[Text.Encoding]::UTF8.GetString($receiptBytes)|ConvertFrom-Json
if($receipt.profile.packageId -cne 'gcc-winlibs@16.1.0' -or $receipt.profile.archiveSha256 -cne '62fb8588d2deee7d662dbcbd386702adbf19643764c971c38aa4839472eee232' -or $receipt.payloadSha256 -cne '004555fc4f053cc1c7ed58594c9c71ab95c902d954b4591a618959b94759564b'){throw 'Foreign compiler profile refused'}
$compilerBefore=Regular $receipt.compiler.path
if($compilerBefore.sha256 -cne '61faf79766e5e4f9170d1a3776ad13b4daf380d11f3d7fbaa0d94c4d71533496' -or $compilerBefore.sha256 -cne $receipt.compiler.sha256){throw 'Compiler image mismatch'}
$prefix=Split-Path (Split-Path $compilerBefore.path -Parent) -Parent
$prefix=Assert-SafeDirectory $prefix
$prefixHold=[NativePythonOwnedPath]::new($prefix,$false);$prefixId=$prefixHold.Identity()
function Prefix-Body {
  $rows=@();$pending=[Collections.Generic.Queue[string]]::new();$pending.Enqueue($prefix)
  while($pending.Count) {
    $directory=$pending.Dequeue()
    foreach($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
      if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Compiler closure reparse refused before descent'}
      $relative=[IO.Path]::GetRelativePath($prefix,$item.FullName)
      if($relative.StartsWith('..') -or [IO.Path]::IsPathRooted($relative)){throw 'Compiler closure escape'}
      if($item.PSIsContainer){$rows += [ordered]@{name=$relative;kind='directory';attributes=[string]$item.Attributes};$pending.Enqueue($item.FullName)}
      else{$file=Regular $item.FullName;$rows += [ordered]@{name=$relative;kind='file';attributes=[string]$item.Attributes;length=$file.length;sha256=$file.sha256}}
    }
  }
  # Match the acquisition's full-name ordering, without recursive traversal
  # through an unexamined directory entry.
  $rows=@($rows|Sort-Object name)
  ConvertTo-Json -InputObject $rows -Depth 8 -Compress
}
$prefixBefore=Prefix-Body
$payload=@{}
foreach($row in @($prefixBefore|ConvertFrom-Json)) {
  $name=$row.name.Replace('\','/')
  if($name -cin @('.repro-receipt','.reprobuild-tarball-receipt.json')){continue}
  if($payload.ContainsKey($name)){throw 'Duplicate actual compiler payload member'}
  $payload[$name]=$row
}
$names=[Collections.Generic.List[string]]::new();foreach($name in $payload.Keys){$names.Add($name)};$names.Sort([StringComparer]::Ordinal)
$canonical=[Text.StringBuilder]::new()
foreach($name in $names){$row=$payload[$name];if($row.kind -ceq 'directory'){[void]$canonical.Append("D`0$name`n")}else{[void]$canonical.Append("F`0$name`0$($row.length)`0$($row.sha256)`n")}}
$actualPayload=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical.ToString()))).ToLowerInvariant()
if($actualPayload -cne '004555fc4f053cc1c7ed58594c9c71ab95c902d954b4591a618959b94759564b'){throw 'Actual compiler runtime/header payload differs from declared archive'}
if($prefixBefore -cne (ConvertTo-Json -InputObject @($receipt.after) -Depth 8 -Compress)){throw 'Compiler complete closure mismatch'}
$git=(Get-Command git.exe -CommandType Application -ErrorAction Stop).Source
$gitBefore=Regular $git
function Git([string[]]$arguments) {
  $start=[Diagnostics.ProcessStartInfo]::new($git)
  $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  foreach($name in @($start.Environment.Keys)){if($name.StartsWith('GIT_',[StringComparison]::OrdinalIgnoreCase)){$null=$start.Environment.Remove($name)}}
  foreach($argument in @('-C',$source)+$arguments){$start.ArgumentList.Add($argument)}
  $process=[Diagnostics.Process]::new();$process.StartInfo=$start
  if(-not $process.Start()){throw 'Metadata Git launch failed'}
  $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  $process.WaitForExit();$text=$stdout.GetAwaiter().GetResult();$diagnostic=$stderr.GetAwaiter().GetResult();$code=$process.ExitCode;$process.Dispose()
  if($code -ne 0){throw 'Selected isolated metadata Git operation failed'}
  $text.Split("`n",[StringSplitOptions]::RemoveEmptyEntries)|ForEach-Object { $_.TrimEnd("`r") }
}
function Source-Body {
  $head=@(Git @('rev-parse','--verify','HEAD'))
  if($head.Count -ne 1 -or $head[0] -cne $SourceRevision){throw 'Source HEAD differs from published pin'}
  $index=@(Git @('ls-files','--stage'))
  $tree=@(Git @('ls-tree','-r','HEAD'))
  # Explicit arrays compare whole stage0 index to the pinned tree.
  if(($index -join "`n") -cne (($tree|ForEach-Object {
    if($_ -cnotmatch '^([0-9]{6}) blob ([0-9a-f]{40})\t(.+)$'){throw 'Nonregular source tree refused'}
    "$($Matches[1]) $($Matches[2]) 0`t$($Matches[3])"
  }) -join "`n")){throw 'Source index differs from pinned tree'}
  $rows=@();$additiveNames=@()
  foreach($entry in $tree) {
    if($entry -cnotmatch '^([0-9]{6}) blob ([0-9a-f]{40})\t(.+)$'){throw 'Malformed pinned member'}
    $mode=$Matches[1];$blob=$Matches[2];$name=$Matches[3]
    if($mode -cnotin @('100644','100755','120000') -or $name.Contains('\') -or $name.Contains("`n")){throw 'Unsupported source member'}
    $file=$null
    if($name.StartsWith('ci/native-conpty/')) {
      if($mode -cnotin @('100644','100755')){throw 'Native component symlink refused'}
      $file=Regular (Join-Path $source $name)
      $actual=@(Git @('hash-object','--no-filters','--',$file.path))
      if($actual.Count -ne 1 -or $actual[0] -cne $blob){throw 'Physical native source differs from pinned blob'}
      $additiveNames += $name
    }
    $rows += [ordered]@{name=$name;mode=$mode;blob=$blob;nativePhysicalFile=$file}
  }
  foreach($required in @('native-channel.c','native-session.c','native-control.c','native-child.c')) {
    if(('ci/native-conpty/'+$required) -cnotin $additiveNames){throw 'Native source member absent'}
  }
  if(@(Git @('status','--porcelain=v1')).Count){throw 'Untracked or modified source refused'}
  ConvertTo-Json -InputObject $rows -Depth 8 -Compress
}
$nativeParent=Get-Item -LiteralPath (Join-Path $source 'ci') -Force
$nativeDirectory=Get-Item -LiteralPath (Join-Path $source 'ci/native-conpty') -Force
foreach($item in @($nativeParent,$nativeDirectory)){if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Native source directory reparse refused'}}
$nativeParentHold=[NativePythonOwnedPath]::new($nativeParent.FullName,$false);$nativeParentId=$nativeParentHold.Identity()
$nativeDirectoryHold=[NativePythonOwnedPath]::new($nativeDirectory.FullName,$false);$nativeDirectoryId=$nativeDirectoryHold.Identity()
$sourceBefore=Source-Body
$pwshBefore=Regular (Get-Process -Id $PID).Path
$runnerBefore=Regular $PSCommandPath
$runnerHold=[NativePythonOwnedPath]::new($PSCommandPath,$false);$runnerId=$runnerHold.Identity()
$parent=Assert-SafeDirectory $env:RUNNER_TEMP
$parentHold=[NativePythonOwnedPath]::new($parent,$false);$parentId=$parentHold.Identity()
$task=Join-Path $parent ('native-conpty-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $task -ErrorAction Stop
$taskHold=[NativePythonOwnedPath]::new($task,$false);$taskId=$taskHold.Identity()
$stages=@();$success=$false;$failure=$null;$control=$null;$unresolvedOwner=$false;$unresolvedIdentities=@()
function Guard {
  if((Get-NativeIdentity $nativeParent.FullName) -cne $nativeParentId -or (Get-NativeIdentity $nativeDirectory.FullName) -cne $nativeDirectoryId){throw 'Held native source directory changed'}
  if((Get-NativeIdentity $source) -cne $sourceId -or (Get-NativeIdentity $prefix) -cne $prefixId -or (Get-NativeIdentity $CompilerReceipt) -cne $receiptId -or (Get-NativeIdentity $OwnedPathHelper) -cne $helperId -or (Get-NativeIdentity $PSCommandPath) -cne $runnerId -or (Get-NativeIdentity $parent) -cne $parentId -or (Get-NativeIdentity $task) -cne $taskId){throw 'Held source/principal/root changed'}
  if((Source-Body) -cne $sourceBefore -or (Prefix-Body) -cne $prefixBefore){throw 'Source/compiler closure changed'}
  foreach($p in @($helperBefore,$compilerBefore,$gitBefore,$pwshBefore,$runnerBefore,$receiptBefore)){if((Regular $p.path).sha256 -cne $p.sha256){throw 'Principal changed'}}
}
function Run-Owned([string]$name,[string]$executable,[string[]]$arguments) {
  Guard
  $principal=Regular $executable
  $start=[Diagnostics.ProcessStartInfo]::new($executable)
  $start.WorkingDirectory=$task;$start.UseShellExecute=$false
  $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  foreach($argument in $arguments){$start.ArgumentList.Add($argument)}
  # Process-local compiler runtime projection; caller PATH is unchanged.
  $start.Environment['PATH']=(Split-Path $compilerBefore.path -Parent)+';'+$start.Environment['PATH']
  foreach($environmentName in @('CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','OBJC_INCLUDE_PATH','LIBRARY_PATH','GCC_EXEC_PREFIX','COMPILER_PATH')){$null=$start.Environment.Remove($environmentName)}
  $process=[Diagnostics.Process]::new();$process.StartInfo=$start
  $outPath=Join-Path $task ($name+'.stdout');$errPath=Join-Path $task ($name+'.stderr')
  $outStream=$null;$errStream=$null;$started=$false
  try {
    $outStream=[IO.File]::Open($outPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $errStream=[IO.File]::Open($errPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    if(-not $process.Start()){throw 'Owned process launch failed'}
    $started=$true;$script:control=$process
    $pidValue=$process.Id;$birth=$process.StartTime.ToUniversalTime().Ticks
    $stdout=$process.StandardOutput.BaseStream.CopyToAsync($outStream)
    $stderr=$process.StandardError.BaseStream.CopyToAsync($errStream)
    $process.WaitForExit();$stdout.GetAwaiter().GetResult();$stderr.GetAwaiter().GetResult()
  } finally {
    # If launch/read fails while alive, preserve exact process and streams.
    # The final receipt remains red and does not release held root authority.
    if(-not $started -or $process.HasExited){if($outStream){$outStream.Dispose()};if($errStream){$errStream.Dispose()}}
  }
  $err=[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($errPath))
  $row=[ordered]@{name=$name;pid=$pidValue;birthUtcTicks=$birth;exit=$process.ExitCode;principal=$principal;stdout=(Regular $outPath);stderr=(Regular $errPath);scope='Exact held direct process; child identities are control raw evidence, not complete descendant census'}
  $script:stages += $row
  if($err.Contains('native_control_unresolved')) {
    $script:unresolvedOwner=$true
    $script:unresolvedIdentities=@($err.Split("`n")|Where-Object { $_ -match '^(native_control_unresolved|unresolved_worker|owned_child) ' })
    # Terminal controller does not establish child/worker ownership completion.
    # Keep its process object and every held root/principal authority reachable.
    throw 'Unresolved live/unknown native descendants refused'
  }
  $process.Dispose();$script:control=$null
  Guard
  if($row.exit -ne 0){throw "Native component failed: $name"}
}
try {
  $child=Join-Path $task 'native-child.exe';$probe=Join-Path $task 'native-control.exe'
  $base=@('-std=c11','-Wall','-Wextra','-Werror')
  Run-Owned 'compile-child' $compilerBefore.path ($base+@((Join-Path $source 'ci/native-conpty/native-child.c'),'-o',$child))
  Run-Owned 'compile-control' $compilerBefore.path ($base+@('-municode',(Join-Path $source 'ci/native-conpty/native-control.c'),'-o',$probe))
  Run-Owned 'native-control' $probe @($child)
  $success=$true
} catch { $failure=$_.Exception.Message;throw } finally {
  try { Guard } catch { $success=$false;$failure=$_.Exception.Message }
  $proof=[ordered]@{scope='Native private C component only; whole pinned Git tree/index plus regular additive physical sources, not every other worktree body; original public API/full75 not qualified';sourceRevision=$SourceRevision;sourceBefore=$sourceBefore;compilerReceipt=$receiptBefore;compiler=$compilerBefore;prefixBefore=$prefixBefore;runner=$runnerBefore;git=$gitBefore;pwsh=$pwshBefore;stages=$stages;success=$success;failure=$failure;unresolvedOwner=$unresolvedOwner;unresolvedIdentities=$unresolvedIdentities;directControl=if($control){@{pid=$control.Id;birthUtcTicks=$control.StartTime.ToUniversalTime().Ticks;terminal=$control.HasExited}}else{$null}}
  $bytes=[Text.Encoding]::UTF8.GetBytes(($proof|ConvertTo-Json -Depth 12))
  $stream=[IO.File]::Open((Join-Path $task 'proof.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
  # Evidence and unknown/live state are retained; no recursive cleanup.
  if(-not $unresolvedOwner -and (-not $control -or $control.HasExited)) {
    foreach($h in @($taskHold,$parentHold,$runnerHold,$prefixHold,$sourceHold,$receiptHold,$helperHold,$nativeParentHold,$nativeDirectoryHold)){$h.Dispose()}
    $helperStream.Dispose()
  }
}

if(-not $success){throw "Native component final authority refused: $failure"}
