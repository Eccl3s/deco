"""Opt-in: assemble every template (or those named) with real Podman.

Usage: templates_podman.py DECO_EXE [TEMPLATE ...]

For each template, checks that the generated configuration assembles, that its
container security options are applied (the capability bounding set, nested
Podman for the podman template), that its toolchain runs the way hooks and
actions run, that the container is reported compatible, and that remove cleans
up. Builds pull each template's base image.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import tomllib

binary=str(pathlib.Path(sys.argv[1]).resolve())
# Keep trust records out of the developer's real state directory.
state_home=tempfile.TemporaryDirectory(prefix='deco-state-')
env=dict(os.environ,XDG_STATE_HOME=state_home.name)
prefix=['podman','--remote=false']
# Capability bit numbers from linux/capability.h, for the names templates use.
BITS={'CHOWN':0,'DAC_OVERRIDE':1,'FOWNER':3,'SETGID':6,'SETUID':7,'NET_ADMIN':12,
      'NET_RAW':13,'SYS_CHROOT':18,'SYS_PTRACE':19,'SYS_ADMIN':21,'MKNOD':27}

# A command each language template's toolchain must run, through the
# configured shell exactly as Deco runs hooks and actions.
TOOLCHAINS={'go':'go version','rust':'cargo --version','python':'uv --version',
            'podman':'podman --version'}

def podman(*args,check=True):
    return subprocess.run(prefix+list(args),check=check,capture_output=True,text=True,timeout=60)

def deco(*args,check=True):
    return subprocess.run([binary]+list(args),check=check,capture_output=True,text=True,timeout=1800,env=env)

def templates():
    listing=deco('init','--list-templates').stdout
    return [line.split()[0] for line in listing.splitlines() if line.strip()]

def cleanup(root,name,container,image):
    # Remove only resources carrying this unique project's ownership labels.
    for kind,ref in [('container',container),('image',image)]:
        found=podman(kind,'inspect','--',ref,check=False)
        if found.returncode: continue
        item=json.loads(found.stdout)[0]
        labels=item['Config']['Labels'] if kind=='container' else item.get('Labels',{})
        if labels.get('dev.deco.project-root')!=str(root) or labels.get('dev.deco.project')!=name: continue
        podman(kind,'rm',*(['--force'] if kind=='container' else ['--no-prune']),'--',item['Id'],check=False)

def check(template):
    with tempfile.TemporaryDirectory(prefix='deco-template-'+template+'-') as directory:
        root=pathlib.Path(directory).resolve()/'project'
        deco('init',str(root),'--template',template)
        config=tomllib.loads((root/'.deco/config.toml').read_text())
        name=config['project']['name']
        settings=config['container']
        container=settings['name']
        image=config['image']['name']+':'+config['image'].get('tag','latest')
        project=['--project-dir',str(root)]
        try:
            validation=deco(*project,'validate').stdout
            for key in ('privileged','devices','cap_add','cap_drop','security_options'):
                assert 'container.'+key not in validation,validation
            deco(*project,'assemble')
            def run(script,check=True):
                return deco(*project,'exec','--','/bin/sh','-c',script,check=check)
            result=run('id -un; pwd')
            assert result.stdout.splitlines()==[config['user']['name'],settings['workdir']],result.stdout
            # The bounding set is what --cap-drop and --cap-add change; the
            # effective set of a non-root user is empty either way.
            status=run('cat /proc/self/status').stdout
            [bounding]=[int(line.split()[1],16) for line in status.splitlines() if line.startswith('CapBnd:')]
            added=settings.get('cap_add',[])
            for cap in added:
                assert bounding & (1<<BITS[cap]),(template,cap,hex(bounding))
            if 'ALL' in settings.get('cap_drop',[]):
                allowed=sum(1<<BITS[cap] for cap in added)
                assert bounding & ~allowed==0,(template,hex(bounding))
            for device in settings.get('devices',[]):
                parts=device.split(':')
                target=parts[1] if len(parts)>1 else parts[0]
                assert run('test -e '+target,check=False).returncode==0,(template,device)
            if template in TOOLCHAINS:
                result=deco(*project,'exec','--',settings['shell'],'-c',TOOLCHAINS[template],check=False)
                assert result.returncode==0,(template,result.stdout,result.stderr)
            if template=='podman':
                result=run('podman info --format "{{.Host.Security.Rootless}}"',check=False)
                assert result.returncode==0 and result.stdout.strip()=='true',result
            report=json.loads(deco(*project,'info','--format','json').stdout)
            assert report['container']['compatible'] is True,report['container']
            assert report['security']=={
                'privileged':settings.get('privileged',False),
                'devices':settings.get('devices',[]),
                'cap_add':added,
                'cap_drop':settings.get('cap_drop',[]),
                'security_options':settings.get('security_options',[])},report['security']
            deco(*project,'remove')
            assert podman('container','exists','--',container,check=False).returncode==1
            assert podman('image','exists','--',image,check=False).returncode==1
        finally:
            cleanup(root,name,container,image)

names=sys.argv[2:] or templates()
failed=[]
for template in names:
    print('==>',template,flush=True)
    try:
        check(template)
        print('    passed',flush=True)
    except (AssertionError,subprocess.CalledProcessError,subprocess.TimeoutExpired) as error:
        detail=error
        if isinstance(error,subprocess.CalledProcessError):
            detail='%s exited %d\nstdout: %s\nstderr: %s'%(error.cmd,error.returncode,error.stdout,error.stderr)
        print('    FAILED:',detail,flush=True)
        failed.append(template)
if failed:
    sys.exit('Templates failed: '+', '.join(failed))
print('All templates passed:',', '.join(names))
