"""Acquire immutable exact766 Darwin Repro package and its real Python daemon.
No mocks, ambient daemon aliases or backend substitution. Both command files
retain held inode/bytes authority; partial activation is red, not atomic success.
Native Darwin execution and all original75 remain mandatory.
"""
from pathlib import Path
import os,sys,subprocess,json,hashlib,stat,tempfile,platform,struct,shutil
ROOT=Path.cwd();R={'success':False,'scope':__doc__}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def run(argv):return subprocess.check_output(argv,cwd=ROOT)
def image(p):
 p=Path(p);q=p.resolve(strict=True);st=q.stat();assert stat.S_ISREG(st.st_mode)
 return {'lexical':str(p),'resolved':str(q),'mode':st.st_mode,'sha256':sha(q)}
def declared_tool(name):
 p=shutil.which(name)
 if p is None:raise RuntimeError('Missing declared native tool: '+name)
 return image(p)
def directory(p):
 st=p.lstat();assert stat.S_ISDIR(st.st_mode) and not p.is_symlink()
 return [st.st_dev,st.st_ino]
def source():
 assert Path(run(['git','rev-parse','--show-toplevel']).decode().strip())==ROOT
 head=run(['git','rev-parse','HEAD']).decode().strip();assert head==os.environ['GITHUB_SHA'],'Owning event mismatch'
 assert run(['git','diff','--cached','--name-only'])==b'' and run(['git','status','--porcelain','--untracked-files=no'])==b''
 rows={}
 for row in run(['git','ls-tree','-rz',head]).split(b'\0'):
  if not row:continue
  meta,name=row.split(b'\t',1);mode,kind,oid=meta.split();p=ROOT/os.fsdecode(name);body=run(['git','cat-file','blob',oid.decode()])
  if mode==b'120000':assert p.is_symlink() and os.fsencode(os.readlink(p))==body
  else:
   assert not p.is_symlink() and p.is_file() and p.read_bytes()==body
   assert bool(p.stat().st_mode&0o111)==(mode==b'100755')
  rows[os.fsdecode(name)]={'gitMode':mode.decode(),'oid':oid.decode(),'sha256':hashlib.sha256(body).hexdigest()}
 return {'head':head,'root':directory(ROOT),'rows':rows}
def closure(output):
 result=json.loads(run(['nix','path-info','--recursive','--json',output]));assert result
 verified={}
 entries=result.items() if isinstance(result,dict) else [(row['path'],row) for row in result]
 for name,row in entries:
  assert name.startswith('/nix/store/') and row['narHash']
  actual=run(['nix','hash','path','--type','sha256','--sri',name]).decode().strip();assert actual==row['narHash']
  verified[name]={'metadata':row,'actualNar':actual}
 return verified
def macho_cpus(path):
 b=Path(path).read_bytes();magic=b[:4]
 if magic in [b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe']:return [struct.unpack_from('<I',b,4)[0]]
 if magic in [b'\xfe\xed\xfa\xcf',b'\xfe\xed\xfa\xce']:return [struct.unpack_from('>I',b,4)[0]]
 assert magic in [b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf']
 count=struct.unpack_from('>I',b,4)[0];assert 0<count<32
 size=32 if magic==b'\xca\xfe\xba\xbf' else 20
 return [struct.unpack_from('>I',b,8+i*size)[0] for i in range(count)]
assert ROOT.is_absolute() and ROOT.resolve()==ROOT
assert platform.system()=='Darwin' and platform.machine()=='arm64','Native Darwin ARM required'
before=source();gitConfiguration=run(['git','config','--null','--show-origin','--show-scope','--list'])
tools={role:declared_tool(role) for role in ['git','nix']};tools['python']=image(sys.executable)
base=Path(os.environ['RUNNER_TEMP']).resolve(strict=True);baseID=directory(base)
receipt=Path(tempfile.mkdtemp(prefix='pty-macos-repro-runtime-',dir=base));receiptID=directory(receipt)
held=[]
def guard_files(expected):
 for command,fd,identity,original in held:
  st=command.lstat();assert stat.S_ISREG(st.st_mode) and st.st_nlink==1 and [st.st_dev,st.st_ino]==identity
  assert os.pread(fd,len(expected[str(command)])+1,0)==expected[str(command)]
def guards(expected):
 assert source()==before and gitConfiguration==run(['git','config','--null','--show-origin','--show-scope','--list'])
 assert tools=={role:image(data['lexical']) for role,data in tools.items()}
 assert directory(base)==baseID and directory(receipt)==receiptID
 guard_files(expected)
try:
 for role in ['GITHUB_ENV','GITHUB_PATH']:
  command=Path(os.environ[role]);assert command.is_absolute() and not command.is_symlink()
  fd=os.open(command,os.O_RDWR|os.O_APPEND|os.O_NOFOLLOW)
  st=os.fstat(fd);held.append((command,fd,[st.st_dev,st.st_ino],b''))
  assert stat.S_ISREG(st.st_mode) and st.st_nlink==1
  original=os.pread(fd,st.st_size,0);assert not original or original.endswith(b'\n'),'Malformed existing activation record'
  held[-1]=(command,fd,[st.st_dev,st.st_ino],original)
 assert held[0][2]!=held[1][2],'Activation files alias'
 expected={str(command):original for command,fd,identity,original in held};guards(expected)
 ref='github:metacraft-labs/reprobuild/76659f5730ecf698b1963c656494d2cb66eb256d#reprobuild'
 sourceRef=ref.split('#')[0]
 metadata=json.loads(run(['nix','flake','metadata','--json','--no-update-lock-file',sourceRef]))
 assert metadata['locked']['rev']=='76659f5730ecf698b1963c656494d2cb66eb256d'
 prefetch=json.loads(run(['nix','flake','prefetch','--json','--no-update-lock-file',sourceRef]))
 assert prefetch['storePath']==metadata['path'] and prefetch['hash']==metadata['locked']['narHash']
 assert run(['nix','hash','path','--type','sha256','--sri',metadata['path']]).decode().strip()==metadata['locked']['narHash']
 R.update(runtimeSource=metadata,runtimeSourcePrefetch=prefetch)
 drv=run(['nix','eval','--raw','--no-update-lock-file',ref+'.drvPath']).decode().strip()
 build=json.loads(run(['nix','build','--no-link','--json','--no-update-lock-file',ref]));assert len(build)==1 and build[0]['drvPath']==drv
 output=build[0]['outputs']['out'];assert output.startswith('/nix/store/') and '\n' not in output
 principals={name:image(Path(output)/name) for name in ['bin/repro','bin/.repro-wrapped','libexec/reprobuild-nix-daemon']}
 for data in principals.values():assert data['resolved'].startswith(output+'/')
 daemonPath=Path(output)/'libexec/reprobuild-nix-daemon'
 daemonBytes=daemonPath.read_bytes();firstLine=daemonBytes.split(b'\n',1)[0]
 sourceDaemon=Path(metadata['path'])/'tools/reprobuild-nix-daemon/reprobuild-nix-daemon'
 assert daemonBytes.split(b'\n',1)[1]==sourceDaemon.read_bytes().split(b'\n',1)[1],'Daemon source body mismatch'
 assert firstLine.startswith(b'#!/nix/store/') and b' ' not in firstLine and firstLine.endswith(b'/bin/python3'),'Undeclared daemon interpreter'
 daemonInterpreter=image(os.fsdecode(firstLine[2:]))
 cpus={'compiledLauncher':macho_cpus(principals['bin/.repro-wrapped']['resolved']),'daemonPython':macho_cpus(daemonInterpreter['resolved'])}
 assert all(0x0100000c in values for values in cpus.values())
 initialClosure=closure(output)
 assert str(Path(daemonInterpreter['resolved']).parents[1]) in initialClosure,'Daemon Python outside declared runtime closure'
 daemonHelp=run([str(Path(output)/'libexec/reprobuild-nix-daemon'),'--help'])
 runtimeVersion=run([str(Path(output)/'bin/repro'),'--version'])
 assert b'0.2.5' in runtimeVersion
 (receipt/'daemon-help.stdout').write_bytes(daemonHelp);(receipt/'runtime-version.stdout').write_bytes(runtimeVersion)
 guards(expected);assert initialClosure==closure(output)
 assert principals=={name:image(Path(output)/name) for name in principals}
 assert daemonInterpreter==image(daemonInterpreter['lexical'])
 additions=[('REPROBUILD_REPRO='+output+'/bin/repro\nREPROBUILD_NIX_DAEMON_BIN='+output+'/libexec/reprobuild-nix-daemon\n').encode(),(output+'/bin\n').encode()]
 for (command,fd,identity,original),addition in zip(held,additions):
  pending=memoryview(addition)
  while pending:
   count=os.write(fd,pending);assert count>0;pending=pending[count:]
  os.fsync(fd);expected[str(command)]=original+addition;guard_files(expected)
 guards(expected);assert initialClosure==closure(output)
 R.update(success=True,sourceBefore=before,sourceAfter=source(),toolsBefore=tools,toolsAfter={role:image(data['lexical']) for role,data in tools.items()},build=build,closureBefore=initialClosure,closureAfter=closure(output),principals=principals,daemonInterpreter=daemonInterpreter,nativeImageCPUs=cpus,runtimeVersionSHA=hashlib.sha256(runtimeVersion).hexdigest(),daemonHelpSHA=hashlib.sha256(daemonHelp).hexdigest(),activationScope='Both held command files appended and verified; partial activation on failure is not success')
finally:
 for command,fd,identity,original in held:os.close(fd)
 R['controllerSHA']=sha(Path(__file__));(receipt/'receipt.json').write_text(json.dumps(R,indent=2)+'\n')
print(receipt/'receipt.json')
