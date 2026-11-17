"""Prepare tagged source archives or package a verified native executable."""
import hashlib
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

def run(*args):
    return subprocess.check_output(args, text=True).strip()

mode, tag, destination = sys.argv[1:4]
if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
    raise SystemExit('Expected a release tag such as v0.1.0')
version = tag[1:]
tag_ref = 'refs/tags/' + tag
out = pathlib.Path(destination).resolve()
out.mkdir(parents=True, exist_ok=True)
if mode == 'source':
    assert run('git', 'rev-parse', tag_ref + '^{commit}') == run('git', 'rev-parse', 'HEAD')
    subprocess.run(['git', 'merge-base', '--is-ancestor', tag_ref, 'origin/main'], check=True)
    text = pathlib.Path('dune-project').read_text()
    assert re.search(r'\(version\s+' + re.escape(version) + r'\)', text)
    assert f'version: "{version}"' in pathlib.Path('deco.opam').read_text()
    archive = out / f'deco-{version}.tar.gz'
    subprocess.run(['git', 'archive', '--format=tar.gz', f'--prefix=deco-{version}/', '-o', str(archive), tag_ref], check=True)
elif mode == 'binary':
    source = pathlib.Path(sys.argv[4]).resolve()
    binary = source / '_build/default/bin/deco.exe'
    assert run(str(binary), '--version') == version
    assert 'X86-64' in run('readelf', '-h', str(binary)).upper()
    symbols = re.findall(r'GLIBC_(\d+)\.(\d+)', run('readelf', '--version-info', str(binary)))
    assert symbols and max((int(a), int(b)) for a, b in symbols) <= (2, 35), symbols
    dependencies = run('ldd', str(binary))
    allowed = {'linux-vdso.so.1', 'libc.so.6', 'libm.so.6', 'libpthread.so.0', 'libdl.so.2', 'librt.so.1', 'ld-linux-x86-64.so.2'}
    for line in dependencies.splitlines():
        assert pathlib.Path(line.split()[0]).name in allowed, dependencies
        assert 'not found' not in line, dependencies
    archive = out / f'deco-{version}-linux-x86_64.tar.gz'
    with tempfile.TemporaryDirectory() as directory:
        package = pathlib.Path(directory) / f'deco-{version}-linux-x86_64'
        package.mkdir()
        shutil.copy2(binary, package / 'deco')
        (package / 'deco').chmod(0o755)
        shutil.copy2(source / 'LICENSE', package / 'LICENSE')
        subprocess.run(['strip', str(package / 'deco')], check=True)
        subprocess.run(['tar', '--sort=name', '--mtime=@' + sys.argv[5], '--owner=0', '--group=0', '--numeric-owner', '-czf', str(archive), '-C', directory, package.name], check=True)
else:
    raise SystemExit('Expected source or binary')
archive.with_name(archive.name + '.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '  ' + archive.name + '\n')
print(archive)
