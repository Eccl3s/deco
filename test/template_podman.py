"""Opt-in default Debian workflow; builds/pulls the unchanged template image."""
import json
import pathlib
import signal
import subprocess
import sys
import tempfile
import tomllib

binary=str(pathlib.Path(sys.argv[1]).resolve())
prefix=['podman','--remote=false']
def podman(*args, check=True):
    return subprocess.run(prefix+list(args),check=check,capture_output=True,text=True,timeout=60)
def terminate(signum,frame):
    raise SystemExit(128+signum)
signal.signal(signal.SIGTERM,terminate)
with tempfile.TemporaryDirectory(prefix='deco-debian-workflow-') as directory:
    root=pathlib.Path(directory).resolve()
    def deco(*args,cwd=None,check=True):
        return subprocess.run([binary]+list(args),check=check,capture_output=True,text=True,timeout=600,cwd=cwd)
    deco('init',str(root))
    # Init normalises the basename differently per resource, so read the names it wrote.
    config=tomllib.loads((root/'.deco/config.toml').read_text())
    name=config['project']['name']
    container=config['container']['name']
    image=config['image']['name']+':'+config['image'].get('tag','latest')
    def listed():
        # Run outside the project: list must not need one. Other projects'
        # managed containers may exist on this host, so keep only ours.
        result=subprocess.run([binary,'list','--format','json'],check=True,capture_output=True,text=True,timeout=60,cwd='/')
        assert result.stderr=='' and result.stdout.endswith(']\n'),result
        return [e for e in json.loads(result.stdout) if e['project_root']==str(root)]
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
        def running():
            return podman('container','inspect','--format','{{.State.Status}}','--',container).stdout.strip()=='running'
        def ids():
            return (podman('container','inspect','--format','{{.Id}}','--',container).stdout.strip(),
                    podman('image','inspect','--format','{{.Id}}','--',image).stdout.strip())
        # list reports the running container with full IDs and its labels.
        container_id,image_id=ids()
        [entry]=listed()
        assert entry=={'project':name,'project_root':str(root),'container':container,
                       'container_id':container_id,'state':'running',
                       'image':entry['image'],'image_id':image_id},entry
        assert entry['image'].endswith(image),entry
        table=subprocess.run([binary,'list'],check=True,capture_output=True,text=True,timeout=60,cwd='/').stdout
        assert container in table and str(root) in table and '\x1b' not in table,table
        # --project selects the listed project by name from an unrelated directory,
        # before or after the command; the lookup and dry runs only read Podman.
        result=deco('-p',name,'exec','--','/bin/sh','-c','pwd; cat .deco-workflow-proof',cwd='/')
        assert result.stdout.splitlines()==['/workspace','verified'],result.stdout
        result=deco('validate','--project',name,cwd='/')
        assert str(root/'.deco/config.toml') in result.stdout,result.stdout
        result=deco('stop','-p',name,'--dry-run',cwd='/')
        assert 'Stop preview' in result.stdout and running(),result.stdout
        # A real stop through --project still passes the ownership checks.
        result=deco('stop','-p',name,cwd='/')
        assert result.stdout=='Stopped '+container+'\n',result.stdout
        [entry]=listed()
        assert entry['container_id']==container_id and entry['state']=='exited',entry
        deco('--project-dir',str(root),'assemble')
        # --keep-image recreates the container from the same image.
        before_container,before_image=ids()
        result=deco('--project-dir',str(root),'refresh','--keep-image')
        assert 'Kept image '+image in result.stdout,result.stdout
        kept_container,kept_image=ids()
        assert kept_container!=before_container and kept_image==before_image and running()
        # A full refresh rebuilds (possibly from cache, so the ID may match) and recreates.
        result=deco('--project-dir',str(root),'refresh')
        assert 'Rebuilt image '+image in result.stdout,result.stdout
        refreshed_container,_=ids()
        assert refreshed_container!=kept_container and running()
        result=deco('--project-dir',str(root),'exec','--','/bin/sh','-c','id -un; pwd; cat .deco-workflow-proof')
        assert result.stdout.splitlines()==['dev','/workspace','verified'],result.stdout
        [entry]=listed()
        assert entry['container_id']==refreshed_container and entry['state']=='running',entry
        deco('--project-dir',str(root),'remove')
        assert listed()==[]
        # With its containers gone, the name no longer selects the project.
        result=deco('-p',name,'validate',cwd='/',check=False)
        assert result.returncode==2 and 'No assembled project' in result.stderr,result
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
        # Refresh can leave the previous image untagged; remove only those labelled for this project.
        listed=podman('images','--all','--filter','label=dev.deco.project-root='+str(root),'--format','{{.ID}}',check=False)
        for image_id in sorted(set(listed.stdout.split())):
            podman('image','rm','--no-prune','--',image_id,check=False)
print('Default Debian workflow passed with unchanged generated files')
