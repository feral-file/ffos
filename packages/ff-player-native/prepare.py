#!/usr/bin/env python3
"""Prepare a deterministic local makepkg source bundle; never publish it."""
import argparse
import hashlib
from pathlib import Path
import shutil
import re

parser=argparse.ArgumentParser()
parser.add_argument('--artifact',type=Path,required=True,help='Tested CI CEF runtime archive')
parser.add_argument('--sha256',help='Expected SHA-256 of the tested CEF archive')
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--version',required=True)
parser.add_argument('--epoch',type=int,required=True,help='Fixed SOURCE_DATE_EPOCH for the intended source revision')
args=parser.parse_args()
if not re.fullmatch(r'[0-9][0-9A-Za-z._]*',args.version) or args.epoch<0: raise SystemExit('Invalid version/epoch')
if args.output.exists(): raise SystemExit('Output must not exist; existing package evidence is never overwritten')
if not args.sha256 or not re.fullmatch(r'[a-f0-9]{64}',args.sha256):
    raise SystemExit('--artifact requires the expected --sha256')
with args.artifact.open('rb') as stream:
    if hashlib.file_digest(stream,'sha256').hexdigest()!=args.sha256:
        raise SystemExit('CEF archive checksum mismatch')
args.output.mkdir(parents=True)
shutil.copyfile(args.artifact,args.output/'ff-player-cef-linux.tar.gz')
template=Path(__file__).with_name('PKGBUILD.cef.in').read_text()
(args.output/'PKGBUILD').write_text(template.replace('@VERSION@',args.version).replace('@SHA256@',args.sha256))
(args.output/'SOURCE_DATE_EPOCH').write_text(str(args.epoch)+'\n')
