#!/usr/bin/python3
"""Stage a Thunderstore BepInEx package for the Valheim server image."""

# A role-local module rather than get_url + unarchive, because what
# turns a Thunderstore zip into a working install is a mapping and not
# an extraction. Packages lay themselves out however their author
# zipped them: a DLL at the root, under `plugins/`, under `Plugins/`,
# with Windows backslashes for separators (Jotunn and WebMap both do,
# which `unzip` warns about and exits non-zero on), with a `patchers/`
# tree for the preloader, or with a `config/` tree. r2modman's
# BepInEx rules are what mod authors test against, so they are what
# this follows. See doc/STATUS.adoc.

import hashlib
import json
import os
import shutil
import tempfile
import urllib.request
import zipfile

from ansible.module_utils.basic import AnsibleModule

DOCUMENTATION = r"""
module: thunderstore_package
short_description: Stage a pinned Thunderstore package for BepInEx
description:
  - Downloads one version of a Thunderstore package, verifies it
    against a pinned SHA-256, and stages it under a BepInEx config
    directory the way r2modman would install it.
  - The package owns C(plugins/<directory>) and, if it ships one,
    C(patchers/<directory>) outright; both are replaced whole on a
    version change, so a file dropped between two versions does not
    survive.
  - Files from the package's C(config/) tree are merged into
    C(bepinex_dir) itself and tracked by hash. One that has been
    edited on the host since it was staged is never overwritten or
    removed, and is reported in C(kept) instead.
  - Idempotent without a network round trip, by comparing a state
    file against the requested version and checksum.
options:
  name:
    description: Package as C(<namespace>-<name>).
    type: str
    required: true
  version:
    description: Package version. Required for state=present.
    type: str
  sha256:
    description: Expected SHA-256 of the zip. Required for
      state=present.
    type: str
  directory:
    description: Directory under plugins/ and patchers/ the package
      owns. Defaults to C(name).
    type: str
  bepinex_dir:
    description: The image's /config/bepinex, on the host.
    type: path
    required: true
  state_dir:
    description: Where the per-package state files live. Must not be
      under bepinex_dir.
    type: path
    required: true
  state:
    type: str
    choices: [present, absent]
    default: present
"""

URL = 'https://thunderstore.io/package/download/{ns}/{pkg}/{version}/'
# Top-level archive folders with a meaning of their own. Matched
# without regard to case, since packages ship both `plugins` and
# `Plugins`. Anything else at the top level is plugin payload.
OWNED = ('plugins', 'patchers')
CONFIG = 'config'
# BepInEx folders a package could target that this module has no
# mapping for. Fail rather than guess where they would have gone.
UNSUPPORTED = ('core', 'monomod')
# Thunderstore's own metadata, which every package carries at its root
# and BepInEx has no use for. Not staged.
METADATA = ('manifest.json', 'icon.png', 'readme.md', 'changelog.md')
# Staged files. The image re-applies its own BEPINEX_CONFIG_*_PERMISSIONS
# to everything under /config/bepinex on start anyway.
FILE_MODE = 0o644
# Bumped whenever the way an archive is mapped onto disk changes, so a
# host staged under the old rules restages every package once rather
# than keeping a layout this module no longer produces.
LAYOUT = 2


def sha256_file(path):
  """Return the hex SHA-256 of a file."""
  digest = hashlib.sha256()
  with open(path, 'rb') as f:
    for chunk in iter(lambda: f.read(1 << 20), b''):
      digest.update(chunk)
  return digest.hexdigest()


def load_state(path):
  """Return the recorded state for a package, or None."""
  try:
    with open(path) as f:
      return json.load(f)
  except FileNotFoundError:
    return None


def split(info):
  """
  Return an archive member's path as a list of parts.

  Empty for directories and Thunderstore metadata, which are not
  staged.
  """
  name = info.filename.replace('\\', '/')
  parts = [p for p in name.split('/') if p]
  if name.endswith('/') or (len(parts) == 1 and parts[0].lower() in METADATA):
    return []
  if any(p in ('.', '..') for p in parts) or ':' in parts[0]:
    raise ValueError(f'unsafe path in archive: {info.filename}')
  return parts


def unwrap(mapped, area, directory):
  """
  Drop the folder an archive's own `area` folder wraps everything in,
  if that folder is named `directory`.

  So that WebMap's plugins/WebMap/WebMap.dll stages as
  plugins/WebMap/WebMap.dll rather than one level deeper. Deliberately
  no broader than that: r2modman never unwraps, and a folder of any
  other name may be one the mod looks for by name - More World
  Locations ships plugins/Bundles/ and loads its assets from there.
  Only what the archive put under `area/` itself counts; loose files
  at its root, such as a LICENSE, land beside the unwrapped ones.
  """
  inner = [rel for _, a, rel, explicit in mapped if a == area and explicit]
  if not inner or any(len(rel) < 2 or rel[0] != directory for rel in inner):
    return mapped
  return [
    (i, a, rel[1:] if a == area and explicit else rel, explicit)
    for i, a, rel, explicit in mapped
  ]


def plan(archive, directory):
  """
  Map each file in the archive to (member, area, relative path).

  `area` is 'plugins', 'patchers' or 'config'.
  """
  mapped = []
  for info in archive.infolist():
    parts = split(info)
    if not parts:
      continue
    top = parts[0].lower()
    if len(parts) > 1 and top in UNSUPPORTED:
      raise ValueError(f'no mapping for {parts[0]}/ in archive')
    if len(parts) > 1 and top in OWNED + (CONFIG,):
      mapped.append((info, top, parts[1:], True))
    else:
      mapped.append((info, 'plugins', parts, False))
  for area in OWNED:
    mapped = unwrap(mapped, area, directory)
  return [(i, a, '/'.join(rel)) for i, a, rel, _ in mapped]


def download(module, url, dest, expected):
  """Fetch url into dest and verify its SHA-256."""
  request = urllib.request.Request(
    url, headers={'User-Agent': 'ansible-valheim'}
  )
  with urllib.request.urlopen(request, timeout=60) as r, open(dest, 'wb') as f:
    shutil.copyfileobj(r, f, 1 << 20)
  actual = sha256_file(dest)
  if actual != expected:
    module.fail_json(
      msg=f'checksum mismatch for {url}: expected {expected}, got {actual}'
    )


def remove_config(bepinex_dir, recorded, kept):
  """Remove staged config files that are unchanged since staging."""
  for rel, digest in recorded.items():
    path = os.path.join(bepinex_dir, rel)
    if not os.path.exists(path):
      continue
    if sha256_file(path) == digest:
      os.unlink(path)
    else:
      kept.append(rel)


def extract(module, p, zip_path, staged):
  """Extract the archive into staged/<area>/, mapped by plan()."""
  with zipfile.ZipFile(zip_path) as archive:
    try:
      files = plan(archive, p['directory'])
    except ValueError as e:
      module.fail_json(msg=f'{p["name"]}: {e}')
    for info, area, rel in files:
      dest = os.path.join(staged, area, rel)
      os.makedirs(os.path.dirname(dest), exist_ok=True)
      with archive.open(info) as src, open(dest, 'wb') as out:
        shutil.copyfileobj(src, out)
      os.chmod(dest, FILE_MODE)


def swap_owned(p, staged, aside):
  """
  Replace the package's owned directories whole.

  Two renames on one filesystem - the old tree aside, the new one in -
  so a run that dies part way leaves a complete version in place, and
  the next run, finding the state file not yet updated, redoes it.
  """
  owned = []
  for area in OWNED:
    target = os.path.join(p['bepinex_dir'], area, p['directory'])
    source = os.path.join(staged, area)
    if os.path.isdir(target):
      os.rename(target, os.path.join(aside, area))
    if os.path.isdir(source):
      os.makedirs(os.path.dirname(target), exist_ok=True)
      os.rename(source, target)
      owned.append(os.path.join(area, p['directory']))
  return owned


def merge_config(bepinex_dir, source_root, previous, kept):
  """
  Copy the package's config files into bepinex_dir.

  A file is only overwritten if it is missing, already identical, or
  unchanged since this module last wrote it. Returns the new record.
  """
  config = {}
  for root, _, names in os.walk(source_root):
    for name in names:
      source = os.path.join(root, name)
      rel = os.path.relpath(source, source_root)
      target = os.path.join(bepinex_dir, rel)
      digest = sha256_file(source)
      if os.path.exists(target):
        current = sha256_file(target)
        if current not in (digest, previous.get(rel)):
          kept.append(rel)
          config[rel] = previous.get(rel, '')
          continue
      os.makedirs(os.path.dirname(target), exist_ok=True)
      shutil.copyfile(source, target)
      os.chmod(target, FILE_MODE)
      config[rel] = digest
  # Files an older version shipped and this one does not.
  remove_config(
    bepinex_dir,
    {k: v for k, v in previous.items() if k not in config},
    kept,
  )
  return config


def install(module, p, state, state_file):
  """Download, verify and stage the package; return the new state."""
  ns, _, pkg = p['name'].partition('-')
  url = URL.format(ns=ns, pkg=pkg, version=p['version'])
  kept = []
  # In state_dir, which is on the same filesystem as bepinex_dir -
  # both are under config_dir - so swap_owned() can rename.
  with tempfile.TemporaryDirectory(dir=p['state_dir']) as tmp:
    zip_path = os.path.join(tmp, 'package.zip')
    download(module, url, zip_path, p['sha256'])
    staged = os.path.join(tmp, 'staged')
    aside = os.path.join(tmp, 'aside')
    os.makedirs(aside)
    extract(module, p, zip_path, staged)
    owned = swap_owned(p, staged, aside)
    config = merge_config(
      p['bepinex_dir'],
      os.path.join(staged, CONFIG),
      (state or {}).get('config', {}),
      kept,
    )

  new_state = {
    'name': p['name'],
    'version': p['version'],
    'sha256': p['sha256'],
    'directory': p['directory'],
    'layout': LAYOUT,
    'owned': owned,
    'config': config,
  }
  with open(state_file + '.tmp', 'w') as f:
    json.dump(new_state, f, indent=2, sort_keys=True)
  os.replace(state_file + '.tmp', state_file)
  return new_state, kept


def main():
  """Run the module."""
  module = AnsibleModule(
    argument_spec={
      'name': {'type': 'str', 'required': True},
      'version': {'type': 'str'},
      'sha256': {'type': 'str'},
      'directory': {'type': 'str'},
      'bepinex_dir': {'type': 'path', 'required': True},
      'state_dir': {'type': 'path', 'required': True},
      'state': {
        'type': 'str',
        'choices': ['present', 'absent'],
        'default': 'present',
      },
    },
    required_if=[('state', 'present', ('version', 'sha256'))],
    supports_check_mode=True,
  )
  p = module.params
  p['directory'] = p['directory'] or p['name']
  if p['sha256']:
    p['sha256'] = p['sha256'].lower()
  if '-' not in p['name'] or '/' in p['directory']:
    module.fail_json(msg='invalid package name or directory')

  state_file = os.path.join(p['state_dir'], p['name'] + '.json')
  state = load_state(state_file)
  result = {'changed': False, 'name': p['name'], 'kept': []}

  if p['state'] == 'absent':
    if state is None:
      module.exit_json(**result)
    result['changed'] = True
    if not module.check_mode:
      for rel in state.get('owned', []):
        shutil.rmtree(os.path.join(p['bepinex_dir'], rel), True)
      remove_config(p['bepinex_dir'], state.get('config', {}), result['kept'])
      os.unlink(state_file)
    module.exit_json(**result)

  current = (
    state is not None
    and state.get('layout') == LAYOUT
    and all(state.get(k) == p[k] for k in ('version', 'sha256', 'directory'))
  )
  # A staged directory deleted by hand is drift, not convergence.
  if current:
    current = all(
      os.path.isdir(os.path.join(p['bepinex_dir'], rel))
      for rel in state.get('owned', [])
    )
  result['version'] = p['version']
  if current:
    module.exit_json(**result)

  result['changed'] = True
  result['previous_version'] = (state or {}).get('version')
  if not module.check_mode:
    _, result['kept'] = install(module, p, state, state_file)
  module.exit_json(**result)


if __name__ == '__main__':
  main()
