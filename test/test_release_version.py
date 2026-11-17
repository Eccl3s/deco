"""Isolated version generator checks; does not create tags in the project."""
import os
import pathlib
import subprocess
import sys
import tempfile

binary=str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='deco-version-') as directory:
    root=pathlib.Path(directory);repo=root/'repo';repo.mkdir();plain=root/'plain';plain.mkdir()
    def git(*args):
        return subprocess.run(['git','-c','commit.gpgsign=false','-c','tag.gpgsign=false',*args],cwd=repo,check=True,capture_output=True,text=True).stdout.strip()
    def version(cwd,metadata='0.1.0',env=None,success=True):
        result=subprocess.run([binary,metadata,str(root/'version.txt')],cwd=cwd,capture_output=True,text=True,env=env)
        assert (result.returncode==0)==success,result
        return (root/'version.txt').read_text() if success else result.stderr
    git('init');git('config','user.name','Version test');git('config','user.email','version@example.invalid')
    tracked=repo/'tracked';tracked.write_text('initial');git('add','.');git('commit','-m','initial');git('tag','-a','v0.1.0','-m','release')
    assert version(repo)=='0.1.0'
    worktree=root/'worktree';git('worktree','add','--detach',str(worktree),'v0.1.0');assert version(worktree)=='0.1.0'
    tracked.write_text('next');git('add','.');git('commit','-m','next')
    assert version(repo).startswith('0.1.0-1-g')
    tracked.write_text('dirty');assert version(repo).endswith('-dirty')
    assert version(plain)=='0.1.0'
    assert version(repo,env=dict(os.environ,PATH='/nonexistent'))=='0.1.0'
    assert 'Missing package version' in version(plain,'',success=False)
print('Release version checks passed')
