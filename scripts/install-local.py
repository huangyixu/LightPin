#!/usr/bin/env python3
"""Install the local signed build at one canonical path, with rollback."""
import pathlib, plistlib, subprocess, shutil, tempfile, os
source = pathlib.Path(__file__).resolve().parent.parent / '.build/app/LightPin.app'
target = pathlib.Path('/Applications/LightPin.app')
def bundle_id(path):
    with (path/'Contents/Info.plist').open('rb') as f:
        return plistlib.load(f).get('CFBundleIdentifier')
if bundle_id(source) != 'local.lightpin.app':
    raise SystemExit('Unexpected source bundle identifier.')
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(source)],check=True)
if subprocess.run(['/usr/bin/pgrep','-x','LightPin'],stdout=subprocess.DEVNULL).returncode == 0:
    raise SystemExit('请先退出正在运行的 LightPin，再安装更新。')
if target.exists() and bundle_id(target) != 'local.lightpin.app':
    raise SystemExit('目标位置不是 LightPin，已停止以避免覆盖其他应用。')
with tempfile.TemporaryDirectory(prefix='.lightpin-install-',dir='/Applications') as directory:
    temporary = pathlib.Path(directory)
    staged = temporary/'LightPin.app'
    backup = temporary/'previous'
    subprocess.run(['/usr/bin/ditto',str(source),str(staged)],check=True)
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(staged)],check=True)
    if target.exists(): os.rename(target,backup)
    try: os.rename(staged,target)
    except BaseException:
        if backup.exists(): os.rename(backup,target)
        raise
register='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
subprocess.run([register,'-u',str(source)],check=False)
subprocess.run([register,'-f',str(target)],check=True)
print('Installed:',target)
