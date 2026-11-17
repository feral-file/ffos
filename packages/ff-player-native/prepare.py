#!/usr/bin/env python3
"""Prepare a deterministic local makepkg source bundle; never publish it."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile

parser=argparse.ArgumentParser()
parser.add_argument('--source',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--version',required=True)
parser.add_argument('--epoch',type=int,required=True,help='Fixed SOURCE_DATE_EPOCH for the intended source revision')
args=parser.parse_args()
if not re.fullmatch(r'[0-9][0-9A-Za-z._]*',args.version) or args.epoch<0: raise SystemExit('Invalid version/epoch')
source=args.source.resolve(strict=True)
if args.output.exists(): raise SystemExit('Output must not exist; existing package evidence is never overwritten')
dependencies=json.loads((source/'dependencies.json').read_text())
files=[]
for name in ('CMakeLists.txt','dependencies.json','README.md'):
    files.append(source/name)
files.extend((source/'docs').glob('*.md'))
for name in ('src','include','cmake','renderers','tools','tests','protocol','maintenance'):
    files.extend(path for path in (source/name).rglob('*') if path.is_file() and '__pycache__' not in path.parts)
for dependency in dependencies.values():
    path=source/'vendor'/dependency['file']
    if hashlib.file_digest(path.open('rb'),'sha256').hexdigest()!=dependency['sha256']:
        raise SystemExit('Dependency checksum mismatch: '+dependency['file'])
    files.append(path)
manifest={'format':'ff-player-native-source','version':1,'packageVersion':args.version,'sourceDateEpoch':args.epoch,'files':{}}
for path in sorted(set(files)):
    if path.is_symlink(): raise SystemExit('Symlink not allowed in source bundle: '+str(path))
    manifest['files'][str(path.relative_to(source))]=hashlib.file_digest(path.open('rb'),'sha256').hexdigest()
args.output.mkdir(parents=True,mode=0o755)
archive=args.output/'ff-player-native-source.tar.gz'
with archive.open('wb') as output, gzip.GzipFile(fileobj=output,mode='wb',filename='',mtime=0,compresslevel=1) as compressed, tarfile.open(fileobj=compressed,mode='w|') as tar:
    for path in sorted(set(files)):
        name='ff-player-native/'+str(path.relative_to(source))
        entry=tarfile.TarInfo(name);entry.size=path.stat().st_size;entry.mtime=args.epoch;entry.mode=0o644
        with path.open('rb') as body: tar.addfile(entry,body)
    body=(json.dumps(manifest,sort_keys=True,indent=2)+'\n').encode()
    entry=tarfile.TarInfo('ff-player-native/source-manifest.json');entry.size=len(body);entry.mtime=args.epoch;entry.mode=0o644
    tar.addfile(entry,io.BytesIO(body))
digest=hashlib.file_digest(archive.open('rb'),'sha256').hexdigest()
template=Path(__file__).with_name('PKGBUILD.in').read_text()
(args.output/'PKGBUILD').write_text(template.replace('@VERSION@',args.version).replace('@SOURCE_SHA256@',digest))
(args.output/'source-manifest.json').write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n')
(args.output/'SOURCE_DATE_EPOCH').write_text(str(args.epoch)+'\n')
print(json.dumps({'archive':str(archive),'sha256':digest,'sourceFiles':len(files),'epoch':args.epoch}))
