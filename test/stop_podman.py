"""Opt-in live stop test. DECO_TEST_IMAGE must name a local image with sleep."""
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import uuid

binary = str(pathlib.Path(sys.argv[1]).resolve())
# Keep trust records out of the developer's real state directory.
state_home = tempfile.TemporaryDirectory(prefix='deco-state-')
env = dict(os.environ, XDG_STATE_HOME=state_home.name)
image = os.environ.get('DECO_TEST_IMAGE')
if not image:
    raise SystemExit('Set DECO_TEST_IMAGE to an existing local image supporting sleep')
prefix = ['podman', '--remote=false']

def podman(*args):
    return subprocess.run(prefix + list(args), check=True, capture_output=True, text=True, timeout=30).stdout.strip()

def terminate(signum, frame):
    raise SystemExit(128 + signum)

signal.signal(signal.SIGTERM, terminate)
podman('image', 'inspect', '--', image)
created = []
with tempfile.TemporaryDirectory(prefix='deco-stop-live-') as directory:
    root = pathlib.Path(directory).resolve()
    (root / '.deco/build').mkdir(parents=True)
    (root / '.deco/build/Containerfile').write_text('FROM scratch\n')
    project = 'deco-stop-' + uuid.uuid4().hex
    def trust():
        subprocess.run([binary, '--project-dir', str(root), 'trust', '--yes'], check=True, capture_output=True, timeout=30, env=env)
    def config(name, trusted=True):
        (root / '.deco/config.toml').write_text(f'[project]\nname="{project}"\n[container]\nname="{name}"\n')
        if trusted:
            trust()
    def stop(expected):
        result = subprocess.run([binary, '--project-dir', str(root), 'stop'], capture_output=True, text=True, timeout=30, env=env)
        assert result.returncode == expected, result
        return result.stdout
    try:
        for managed in [True, False]:
            name = project + ('-managed' if managed else '-unmanaged')
            labels = ['--label', 'dev.deco.managed=true', '--label', 'dev.deco.project=' + project,
                      '--label', 'dev.deco.project-root=' + str(root)] if managed else []
            cid = podman('create', '--name', name, '--pull=never', *labels, '--entrypoint', 'sleep', '--', image, '300')
            created.append(cid)
            podman('start', '--', cid)
            config(name, trusted=not managed)
            if managed:
                # Untrusted configuration is refused before Podman is touched.
                stop(5)
                assert podman('container', 'inspect', '--format', '{{.State.Status}}', cid) == 'running'
                trust()
                assert stop(0) == f'Stopped {name}\n'
                assert podman('container', 'inspect', '--format', '{{.State.Status}}', cid) == 'exited'
                assert stop(0) == f'Already stopped: {name}\n'
                # --no-hooks proceeds without trust, with a warning.
                subprocess.run([binary, '--project-dir', str(root), 'trust', '--revoke'], check=True, capture_output=True, timeout=30, env=env)
                result = subprocess.run([binary, '--project-dir', str(root), 'stop', '--no-hooks'], capture_output=True, text=True, timeout=30, env=env)
                assert result.returncode == 0 and result.stdout == f'Already stopped: {name}\n', result
                assert 'pre_stop is skipped' in result.stderr, result
            else:
                stop(4)
                assert podman('container', 'inspect', '--format', '{{.State.Status}}', cid) == 'running'
    finally:
        for cid in reversed(created):
            subprocess.run(prefix + ['rm', '--force', '--', cid], check=True, capture_output=True, timeout=30)
print('Disposable Podman stop checks passed')
