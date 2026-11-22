"""Opt-in Linux PTY checks; no Podman resources are created."""
import fcntl
import json
import os
import pathlib
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

binary = str(pathlib.Path(sys.argv[1]).resolve())
# Keep trust records out of the developer's real state directory.
state_home = tempfile.TemporaryDirectory(prefix='deco-state-')
with tempfile.TemporaryDirectory(prefix='deco-shell-pty-') as directory:
    root = pathlib.Path(directory)
    (root / '.deco/build').mkdir(parents=True)
    (root / '.deco/config.toml').write_text('[project]\nname="example"\n[container]\nshell="/bin/sh"\n')
    (root / '.deco/build/Containerfile').write_text('FROM scratch\n')
    fake = root / 'podman'
    fake.write_text('#!' + sys.executable + '\n' + '''
import json, os, pathlib, sys
root=pathlib.Path.cwd(); a=sys.argv[1:]; assert a.pop(0)=='--remote=false'
mode=os.environ['DECO_PTY_MODE']; marker=root/'started'
with open(root/'calls','a') as log: log.write(json.dumps(a)+'\\n')
labels={'dev.deco.managed':'true','dev.deco.project':'foreign' if mode=='owner' else 'example','dev.deco.project-root':str(root)}
if a[0]=='version': sys.exit(125 if mode=='unavailable' else 0)
elif a[:2]==['image','inspect']: print(json.dumps([dict(Id='iid',Labels=labels,Config=dict(WorkingDir='/'))]))
elif a[:2]==['container','inspect']:
 if mode=='missing': sys.exit(125)
 print(json.dumps([dict(Id='cid',Image='iid',State=dict(Status='exited' if mode=='stopped' and not marker.exists() else 'running'),Config=dict(Labels=labels,WorkingDir='/'),HostConfig=dict(UsernsMode='',Init=True),Mounts=[])]))
elif a[:2]==['container','exists']: sys.exit(1)
elif a[0]=='start': marker.touch()
elif a[0]=='exec':
 assert a==['exec','--interactive','--tty','--','cid','/bin/sh'],a
 os.execv('/bin/sh',['/bin/sh'])
else: sys.exit(99)
''')
    fake.chmod(0o700)
    # The first mode runs before the project is trusted.
    for mode, expected in [('untrusted',5), ('running',17), ('stopped',17), ('interrupt',0), ('missing',4), ('owner',4), ('unavailable',3), ('stdin-only',2), ('stdout-only',2)]:
        (root/'calls').write_text('')
        (root/'started').unlink(missing_ok=True)
        if mode == 'running':
            subprocess.run([binary,'--project-dir',str(root),'trust','--yes'],check=True,capture_output=True,
                           env=dict(os.environ,XDG_STATE_HOME=state_home.name))
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(root)
            os.environ['PATH'] = directory + ':' + os.environ['PATH']
            os.environ['DECO_PTY_MODE'] = mode
            os.environ['XDG_STATE_HOME'] = state_home.name
            if mode == 'stdin-only':
                fd=os.open('/dev/null',os.O_WRONLY); os.dup2(fd,1); os.close(fd)
            if mode == 'stdout-only':
                fd=os.open('/dev/null',os.O_RDONLY); os.dup2(fd,0); os.close(fd)
            os.execv(binary,[binary,'shell'])
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH',31,91,0,0))
        data=b''; status=None; sent=False; interrupted=False
        deadline=time.monotonic()+8
        try:
            while time.monotonic()<deadline:
                if select.select([master],[],[],0.02)[0]:
                    try: data+=os.read(master,4096)
                    except OSError: pass
                if not sent and mode in ('running','stopped','interrupt') and (b'#' in data or b'$' in data):
                    os.write(master,b'echo READY; sleep 5\n' if mode=='interrupt' else b'stty size; read value; echo GOT:$value; exit 17\nhello\n')
                    sent=True
                if mode=='interrupt' and b'READY\r\n' in data and not interrupted:
                    os.write(master,b'\x03'); interrupted=True
                    os.write(master,b'exit 0\n')
                child,result=os.waitpid(pid,os.WNOHANG)
                if child: status=result; break
            assert status is not None, (mode,data)
            assert os.waitstatus_to_exitcode(status)==expected,(mode,status,data)
            if mode in ('running','stopped'):
                assert b'31 91' in data and b'GOT:hello' in data,(mode,data)
            calls=(root/'calls').read_text()
            if mode in ('stdin-only','stdout-only','untrusted'): assert calls==''
            if mode == 'untrusted': assert b'is not trusted' in data,(mode,data)
            assert '"stop"' not in calls and '"remove"' not in calls
        finally:
            if status is None:
                os.killpg(pid,signal.SIGKILL); os.waitpid(pid,0)
            os.close(master)
print('Shell PTY checks passed')
