"""Exercise packaging with a read-only input; ABI tools are isolated fixtures."""
import hashlib
import os
import pathlib
import stat
import subprocess
import sys
import tarfile
import tempfile

prepare = str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='deco-package-test-') as directory:
    root = pathlib.Path(directory)
    source = root / 'source'
    binary = source / '_build/default/bin/deco.exe'
    binary.parent.mkdir(parents=True)
    binary.write_text('#!/bin/sh\necho 0.1.0\n')
    binary.chmod(0o555)
    (source / 'LICENSE').write_text('test license')
    tools = root / 'tools'
    tools.mkdir()
    for name in ['readelf', 'ldd', 'strip']:
        path = tools / name
        path.write_text('#!' + sys.executable + '\n' + '''
import os, pathlib, stat, sys
name=pathlib.Path(sys.argv[0]).name
if name=='readelf': print('Advanced Micro Devices X86-64' if sys.argv[1]=='-h' else 'GLIBC_2.35')
elif name=='ldd': print('libc.so.6 => /lib/libc.so.6 (0x123)')
else:
    target=pathlib.Path(sys.argv[1])
    assert stat.S_IMODE(target.stat().st_mode)==0o755
    with target.open('a') as output: output.write('# stripped fixture\\n')
''')
        path.chmod(0o755)
    dist = root / 'dist'
    subprocess.run([sys.executable, prepare, 'binary', 'v0.1.0', str(dist), str(source), '0'],
                   env=dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH']), check=True)
    assert stat.S_IMODE(binary.stat().st_mode) == 0o555
    archive = dist / 'deco-0.1.0-linux-x86_64.tar.gz'
    with tarfile.open(archive) as contents:
        member = contents.getmember('deco-0.1.0-linux-x86_64/deco')
        assert member.mode == 0o755
        assert b'stripped fixture' in contents.extractfile(member).read()
        assert contents.extractfile('deco-0.1.0-linux-x86_64/LICENSE').read() == b'test license'
    assert archive.with_name(archive.name + '.sha256').read_text() == hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n'
print('Read-only binary packaging regression passed')
