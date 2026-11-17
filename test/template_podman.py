"""Opt-in default Debian workflow; builds/pulls the unchanged template image."""
import json
import pathlib
import signal
import subprocess
import sys
import tempfile

binary=str(pathlib.Path(sys.argv[1]).resolve())
prefix=['podman','--remote=false']
def podman(*args, check=True):
    return subprocess.run(prefix+list(args),check=check,capture_output=True,text=True,timeout=60)
def terminate(signum,frame):
    raise SystemExit(128+signum)
signal.signal(signal.SIGTERM,terminate)
with tempfile.TemporaryDirectory(prefix='deco-debian-workflow-') as directory:
    root=pathlib.Path(directory).resolve()
    def deco(*args):
        return subprocess.run([binary]+list(args),check=True,capture_output=True,text=True,timeout=600)
    deco('init',str(root))
    # Init generates these names from the already-safe temporary basename.
    name=root.name
    container=name+'-dev-container';image=name+'-dev-image:latest'
    originals={p:p.read_bytes() for p in (root/'.deco/config.toml',root/'.deco/build/Containerfile')}
    try:
        result=deco('--project-dir',str(root),'validate')
        assert 'container.cap_drop' in result.stdout and 'network.mode' in result.stdout
        assert 'pasta' not in result.stdout and 'ALL' not in result.stdout
        deco('--project-dir',str(root),'assemble','--dry-run')
        deco('--project-dir',str(root),'assemble')
        result=deco('--project-dir',str(root),'exec','--','/bin/sh','-c','id -un; pwd; printf verified > .deco-workflow-proof')
        assert result.stdout.splitlines()==['dev','/workspace'],result.stdout
        assert (root/'.deco-workflow-proof').read_text()=='verified'
        deco('--project-dir',str(root),'stop')
        deco('--project-dir',str(root),'assemble')
        deco('--project-dir',str(root),'remove')
        assert podman('container','exists','--',container,check=False).returncode==1
        assert podman('image','exists','--',image,check=False).returncode==1
        for path,original in originals.items(): assert path.read_bytes()==original
    finally:
        # Cleanup only resources carrying this unique project's ownership labels.
        for kind,ref in [('container',container),('image',image)]:
            found=podman(kind,'inspect','--',ref,check=False)
            if found.returncode: continue
            item=json.loads(found.stdout)[0]
            labels=item['Config']['Labels'] if kind=='container' else item.get('Labels',{})
            assert labels.get('dev.deco.project-root')==str(root) and labels.get('dev.deco.project')==name
            podman(kind,'rm',*(['--force'] if kind=='container' else ['--no-prune']),'--',item['Id'])
print('Default Debian workflow passed with unchanged generated files')
