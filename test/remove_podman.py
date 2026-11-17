"""Opt-in removal integration test; only uniquely labelled child images are deleted."""
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import uuid

binary = str(pathlib.Path(sys.argv[1]).resolve())
base = os.environ.get('DECO_TEST_IMAGE')
if not base:
    raise SystemExit('Set DECO_TEST_IMAGE to a local image supporting sleep')
prefix = ['podman', '--remote=false']

def podman(*args, check=True):
    result = subprocess.run(prefix + list(args), capture_output=True, text=True, timeout=60)
    if check and result.returncode:
        raise RuntimeError((args, result.stderr))
    return result

base_id = podman('image', 'inspect', '--format', '{{.Id}}', '--', base).stdout.strip()
containers = []
images = set()

def terminate(signum, frame):
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, terminate)
with tempfile.TemporaryDirectory(prefix='deco-remove-live-') as directory:
    root = pathlib.Path(directory).resolve()
    (root / '.deco/build').mkdir(parents=True)
    project = 'deco-remove-' + uuid.uuid4().hex
    image_name = 'localhost/' + project
    labels = ['--label', 'dev.deco.managed=true', '--label', 'dev.deco.project=' + project,
              '--label', 'dev.deco.project-root=' + str(root)]
    def config(name):
        (root / '.deco/config.toml').write_text(f'[project]\nname="{project}"\n[image]\nname="{image_name}"\n[container]\nname="{name}"\n')
    def build():
        path = root / '.deco/build/Containerfile'
        path.write_text('FROM ' + base_id + '\n')
        podman('build', '--pull=never', '--network=none', '--tag', image_name + ':latest',
               *labels, '--file', str(path), str(path.parent))
        iid = podman('image', 'inspect', '--format', '{{.Id}}', image_name).stdout.strip()
        assert iid != base_id
        images.add(iid)
        return iid
    def create(managed=True):
        name = project + '-' + uuid.uuid4().hex
        cid = podman('create', '--init', '--name', name, '--pull=never',
                     *(labels if managed else ['--label', 'dev.deco.managed=false']), '--entrypoint', 'sleep', '--', image_name, '300').stdout.strip()
        containers.append(cid)
        podman('start', '--', cid)
        return name, cid
    def remove(expected, *args):
        result = subprocess.run([binary, '--project-dir', str(root), 'remove', *args], capture_output=True, text=True, timeout=60)
        assert result.returncode == expected, result
        return result
    def exists(kind, ref):
        return podman(kind, 'exists', '--', ref, check=False).returncode == 0
    try:
        iid = build()
        name,cid = create(); config(name)
        remove(0, '--keep-image'); assert not exists('container',cid) and exists('image',iid)
        name,cid = create(); config(name)
        _,dependent = create(False)
        result=remove(4)
        assert dependent in result.stderr and not exists('container',cid) and exists('image',iid)
        assert podman('container','inspect','--format','{{.State.Status}}',dependent).stdout.strip()=='running'
        podman('stop','--',dependent)
        remove(4)
        assert podman('container','inspect','--format','{{.State.Status}}',dependent).stdout.strip()=='exited'
        podman('container','rm','--',dependent)
        remove(0); remove(0); assert not exists('image',iid)
        iid=build(); name,cid=create(); config(name)
        remove(0); assert not exists('container',cid) and not exists('image',iid)
        iid=build(); name,cid=create(False); config(name)
        remove(4,'--keep-image')
        assert exists('container',cid) and exists('image',iid)
    finally:
        failures=[]
        for cid in reversed(containers):
            if exists('container',cid):
                result=podman('container','rm','--force','--',cid,check=False)
                if result.returncode: failures.append(result.stderr)
        for iid in images:
            if exists('image',iid):
                result=podman('image','rm','--no-prune','--',iid,check=False)
                if result.returncode: failures.append(result.stderr)
        assert exists('image',base_id), 'Supplied base image disappeared'
        if failures: raise RuntimeError(failures)
print('Disposable Podman removal checks passed')
