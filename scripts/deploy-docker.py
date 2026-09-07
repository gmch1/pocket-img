"""Install a verified release bundle without replacing user-edited configs."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def deploy(source, target, port):
    source, target = Path(source).resolve(), Path(target).absolute()
    files = ('compose.yaml', 'scripts/install-docker.sh', 'scripts/deploy-docker.py')
    # Reject symlinked path components before reading or writing managed files.
    for path in (target, *target.parents, target / 'scripts', target / '.pocketimg-install.json'):
        if path.is_symlink():
            raise ValueError(f'安装目录不能经过符号链接：{path}')
    target.mkdir(parents=True, exist_ok=True)
    marker = target / '.pocketimg-install.json'
    if any(target.iterdir()):
        if not marker.is_file():
            raise ValueError('目录非空且不是此入口管理的安装；请选择空目录，不会覆盖现有文件。')
        previous = json.loads(marker.read_text())
        for name in files:
            path = target / name
            if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != previous.get(name):
                raise ValueError(f'安装文件已被修改，停止覆盖：{name}；请备份并手工合并新部署包。')
    (target / 'scripts').mkdir(exist_ok=True)
    checksums = {}
    for name in files:
        data = (source / name).read_bytes()
        path = target / name
        path.write_bytes(data)
        checksums[name] = hashlib.sha256(data).hexdigest()
    marker.write_text(json.dumps(checksums, indent=2) + '\n')
    args = ['bash', str(target / 'scripts/install-docker.sh')]
    if port:
        args += ['--port', port]
    print(f'部署目录：{target}；保留此目录和 Docker 数据卷以便后续管理。', flush=True)
    subprocess.run(args, check=True, env=os.environ)


if __name__ == '__main__':
    try:
        deploy(*sys.argv[1:])
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
