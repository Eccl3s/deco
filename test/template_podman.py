"""Opt-in default Debian workflow; builds/pulls the unchanged template image."""
import datetime
import json
import os
import pathlib
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time
import tomllib

binary=str(pathlib.Path(sys.argv[1]).resolve())
# Keep trust records out of the developer's real state directory.
state_home=tempfile.TemporaryDirectory(prefix='deco-state-')
env=dict(os.environ,XDG_STATE_HOME=state_home.name)
prefix=['podman','--remote=false']
def podman(*args, check=True):
    return subprocess.run(prefix+list(args),check=check,capture_output=True,text=True,timeout=60)
def terminate(signum,frame):
    raise SystemExit(128+signum)
signal.signal(signal.SIGTERM,terminate)
with tempfile.TemporaryDirectory(prefix='deco-debian-workflow-') as directory:
    root=pathlib.Path(directory).resolve()
    def deco(*args,cwd=None,check=True):
        return subprocess.run([binary]+list(args),check=check,capture_output=True,text=True,timeout=600,cwd=cwd,env=env)
    deco('init',str(root))
    # Init normalises the basename differently per resource, so read the names it wrote.
    config=tomllib.loads((root/'.deco/config.toml').read_text())
    name=config['project']['name']
    container=config['container']['name']
    image=config['image']['name']+':'+config['image'].get('tag','latest')
    def listed():
        # Run outside the project: list must not need one. Other projects'
        # managed containers may exist on this host, so keep only ours.
        result=subprocess.run([binary,'list','--format','json'],check=True,capture_output=True,text=True,timeout=60,cwd='/',env=env)
        assert result.stderr=='' and result.stdout.endswith(']\n'),result
        return [e for e in json.loads(result.stdout) if e['project_root']==str(root)]
    def info(*args,cwd=None):
        # Read the report outside the project unless a directory is given.
        result=deco(*args,'info','--format','json',cwd=cwd or '/')
        assert result.stderr=='' and result.stdout.endswith('}\n'),result
        return json.loads(result.stdout)
    def created(report,kind):
        # UTC, second precision, and not after now.
        text=report[kind]['created']
        assert text.endswith('Z') and '.' not in text,report
        when=datetime.datetime.strptime(text,'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
        assert when<=datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=5),report
    originals={p:p.read_bytes() for p in (root/'.deco/config.toml',root/'.deco/build/Containerfile')}
    try:
        result=deco('--project-dir',str(root),'validate')
        # Security options are applied, so only network.mode is still ignored.
        assert 'container.cap_drop' not in result.stdout and 'network.mode' in result.stdout
        assert 'pasta' not in result.stdout and 'ALL' not in result.stdout
        deco('--project-dir',str(root),'assemble','--dry-run')
        deco('--project-dir',str(root),'assemble')
        result=deco('--project-dir',str(root),'exec','--','/bin/sh','-c','id -un; pwd; printf verified > .deco-workflow-proof')
        assert result.stdout.splitlines()==['dev','/workspace'],result.stdout
        assert (root/'.deco-workflow-proof').read_text()=='verified'
        # cap_drop = ["ALL"] empties the capability bounding set.
        result=deco('--project-dir',str(root),'exec','--','/bin/sh','-c','grep ^CapBnd: /proc/self/status')
        assert result.stdout.split()==['CapBnd:','0000000000000000'],result.stdout
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
        # info reports the owned, compatible, running environment.
        report=info('--project-dir',str(root))
        assert report['project']=={'name':name,'description':config['project']['description'],
                                   'root':str(root),'config':str(root/'.deco/config.toml')},report
        assert report['podman']['available'] is True and report['podman']['version'],report
        assert {k:report['image'][k] for k in ('id','exists','owned')}=={'id':image_id,'exists':True,'owned':True},report
        assert {k:report['container'][k] for k in ('id','exists','state','podman_state','owned','compatible','incompatibilities')}=={
            'id':container_id,'exists':True,'state':'running','podman_state':'running',
            'owned':True,'compatible':True,'incompatibilities':[]},report
        created(report,'image'); created(report,'container')
        assert report['runtime']=={'user_mode':'keep-id','workdir':'/workspace','shell':'bash'},report
        assert report['security']=={'privileged':False,'devices':[],'cap_add':[],
                                    'cap_drop':['ALL'],'security_options':[]},report
        # .deco is mounted read-only over the workspace; the project has no .git.
        assert report['protection']=={'deco':'protected','git':'not-applicable'},report
        assert report['mounts']==[{'source':str(root),'target':'/workspace','type':'bind',
                                   'readonly':False,'relabel':'private','protected':False},
                                  {'source':str(root/'.deco'),'target':'/workspace/.deco','type':'bind',
                                   'readonly':True,'relabel':'none','protected':True}],report
        human=deco('info',cwd=root).stdout
        assert container_id in human and ' UTC (' in human and 'Compatible:  yes' in human,human
        assert '\x1b' not in human and 'network.mode' in human,human
        table=subprocess.run([binary,'list'],check=True,capture_output=True,text=True,timeout=60,cwd='/',env=env).stdout
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
        # info finds the project by name and reports the stopped container.
        report=info('-p',name)
        assert report['project']['root']==str(root),report
        assert report['container']['state']=='stopped' and report['container']['podman_state']=='exited',report
        assert report['container']['id']==container_id and report['container']['compatible'] is True,report
        # start previews without changing anything, then restarts the same
        # container by name from an unrelated directory; repeating it is a no-op.
        result=deco('start','-p',name,'--dry-run',cwd='/')
        assert 'Start preview' in result.stdout and not running(),result.stdout
        result=deco('-p',name,'start',cwd='/')
        assert result.stdout=='Started '+container+'\n',result.stdout
        assert running() and ids()[0]==container_id
        result=deco('start','--project',name,cwd='/')
        assert result.stdout=='Already running: '+container+'\n',result.stdout
        assert ids()[0]==container_id
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
        # Environment: literal values and an env file reach the container,
        # values never appear in previews or reports, and a changed
        # environment needs a refresh while editing the env file does not.
        config_path=root/'.deco/config.toml'
        env_file=root/'.deco-env'
        env_file.write_text('FROM_FILE=file value\nSHARED=from-file\n')
        text=originals[config_path].decode()
        assert text.count('[container]\n')==1,text
        config_path.write_text(text.replace('[container]\n','[container]\nenv_files = [".deco-env"]\n')
            +'\n[container.environment]\nLITERAL = "$HOME; $(false)"\nSHARED = "from-config"\n')
        result=deco('--project-dir',str(root),'validate')
        assert 'environment' not in result.stdout and 'env_files' not in result.stdout,result.stdout
        result=deco('--project-dir',str(root),'trust','--yes')
        assert '$(false)' not in result.stdout and 'from-config' not in result.stdout,result.stdout
        result=deco('--project-dir',str(root),'exec','--','true',check=False)
        assert result.returncode==4 and 'run deco refresh' in result.stderr,result
        result=deco('--project-dir',str(root),'refresh','--keep-image','--dry-run')
        assert "--env 'LITERAL=<hidden>'" in result.stdout and '--env-file '+str(env_file) in result.stdout,result.stdout
        assert '$(false)' not in result.stdout and 'from-config' not in result.stdout,result.stdout
        deco('--project-dir',str(root),'refresh','--keep-image')
        def container_env():
            result=deco('--project-dir',str(root),'exec','--','env')
            return dict(line.split('=',1) for line in result.stdout.splitlines() if '=' in line)
        variables=container_env()
        # --env overrides the env file whatever their order.
        assert variables['LITERAL']=='$HOME; $(false)' and variables['SHARED']=='from-config',variables
        assert variables['FROM_FILE']=='file value',variables
        report=info('--project-dir',str(root))
        assert report['environment']=={'variables':['LITERAL','SHARED'],'env_files':[str(env_file)]},report
        assert report['container']['compatible'] is True,report
        human=deco('info',cwd=root).stdout
        assert '$(false)' not in human and 'from-config' not in human and 'file value' not in human,human
        env_file.write_text('FROM_FILE=edited\n')
        assert container_env()['FROM_FILE']=='file value'
        # Restoring the original configuration restores its earlier approval;
        # the container then needs recreating without the environment.
        config_path.write_bytes(originals[config_path]); env_file.unlink()
        deco('--project-dir',str(root),'refresh','--keep-image')
        assert 'LITERAL' not in container_env()
        # Lifecycle hooks: each appends its name to a marker in the workspace,
        # which the hooks see as their working directory.
        hook_names=['post_create','post_start','pre_enter','pre_stop']
        config_path.write_text(originals[config_path].decode()+'\n[hooks]\n'+''.join(
            '%s = "printf \'%s\\\\n\' >> .deco-hooks"\n'%(hook,hook) for hook in hook_names)
            +'[actions]\nproof = "printf ran > .deco-action-proof; exit 3"\n')
        deco('--project-dir',str(root),'trust','--yes')
        marker=root/'.deco-hooks'
        def ran():
            if not marker.exists(): return []
            names=marker.read_text().split(); marker.unlink(); return names
        result=deco('--project-dir',str(root),'assemble','--dry-run')
        assert 'post_create hook' in result.stdout and 'post_start hook' in result.stdout,result.stdout
        assert ran()==[]
        # Already running: assemble repeats no hook.
        deco('--project-dir',str(root),'assemble')
        assert ran()==[]
        deco('--project-dir',str(root),'stop')
        assert ran()==['pre_stop'] and not running()
        deco('--project-dir',str(root),'start')
        assert ran()==['post_start'] and running()
        deco('--project-dir',str(root),'stop','--no-hooks')
        assert ran()==[] and not running()
        # exec starts the stopped container and runs post_start first.
        result=deco('--project-dir',str(root),'exec','--','/bin/sh','-c','cat .deco-hooks')
        assert result.stdout=='post_start\n',result.stdout
        assert ran()==['post_start'] and running()
        # Actions: listing needs no container; run uses exec's path, so it
        # starts a stopped container (running post_start) and passes the
        # action's exit status through.
        result=deco('--project-dir',str(root),'actions','--format','json')
        assert json.loads(result.stdout)==[{'name':'proof','command':'printf ran > .deco-action-proof; exit 3'}],result.stdout
        deco('--project-dir',str(root),'stop','--no-hooks')
        assert not running()
        action_proof=root/'.deco-action-proof'
        result=deco('--project-dir',str(root),'run','proof',check=False)
        assert result.returncode==3,result
        assert action_proof.read_text()=='ran' and ran()==['post_start'] and running()
        action_proof.unlink()
        result=deco('-p',name,'run','proof',cwd='/',check=False)
        assert result.returncode==3 and action_proof.read_text()=='ran' and ran()==[],result
        action_proof.unlink()
        result=deco('--project-dir',str(root),'run','nope',check=False)
        assert result.returncode==2 and "run 'deco actions'" in result.stderr,result
        # shell runs pre_enter immediately before entry.
        pid,master=pty.fork()
        if pid==0:
            os.environ.update(env)
            os.execv(binary,[binary,'--project-dir',str(root),'shell'])
        data=b''; status=None; sent=False; deadline=time.monotonic()+120
        try:
            while time.monotonic()<deadline:
                if select.select([master],[],[],0.1)[0]:
                    try: data+=os.read(master,4096)
                    except OSError: pass
                if not sent and (b'$ ' in data or b'# ' in data):
                    os.write(master,b'exit 0\n'); sent=True
                child,result_status=os.waitpid(pid,os.WNOHANG)
                if child: status=result_status; break
        finally:
            if status is None:
                os.kill(pid,signal.SIGKILL); os.waitpid(pid,0)
            os.close(master)
        assert status is not None and os.waitstatus_to_exitcode(status)==0,(status,data)
        assert ran()==['pre_enter'],data
        result=deco('--project-dir',str(root),'refresh','--keep-image')
        assert ran()==['pre_stop','post_create','post_start'] and running()
        # A new container runs post_create before post_start.
        deco('--project-dir',str(root),'remove','--keep-image')
        assert ran()==['pre_stop']
        deco('--project-dir',str(root),'assemble')
        assert ran()==['post_create','post_start'] and running()
        # Restoring the original configuration restores its earlier approval.
        config_path.write_bytes(originals[config_path])
        deco('--project-dir',str(root),'remove')
        assert ran()==[] and listed()==[]
        # After remove, info still succeeds and reports both resources missing.
        report=info('--project-dir',str(root))
        for kind in ('image','container'):
            assert {k:report[kind][k] for k in ('id','exists','created','owned')}=={
                'id':None,'exists':False,'created':None,'owned':None},report
        assert report['container']['state'] is None and report['container']['compatible'] is None,report
        # With its containers gone, the name no longer selects the project.
        result=deco('-p',name,'validate',cwd='/',check=False)
        assert result.returncode==2 and 'No assembled project' in result.stderr,result
        # start never creates a container: it directs the user to assemble.
        result=deco('--project-dir',str(root),'start',check=False)
        assert result.returncode==4 and 'run deco assemble' in result.stderr,result
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
