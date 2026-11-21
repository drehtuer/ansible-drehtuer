"""
Check that every pinned release tarball's checksum matches upstream.

Renovate moves a pin's `version` but cannot compute the checksum
beside it, and twice a version reached `main` with the previous
release's checksum still in place (Nextcloud 35.0.3 in #186,
Prometheus 3.16.0 in #193). The deploy then fails at the download -
safely, before the host is touched, but only once someone runs it.
This catches it on the pull request instead.

A pin is a `# renovate: ... depName=<name>` comment directly above a
`version:` key. If the mapping holding that `version` also holds a
`checksum` or `checksums`, the values are compared against the
checksum file upstream publishes for that version. A pin with a
checksum and no entry in `UPSTREAM` is an error, not a skip, so a new
one cannot go unchecked by being forgotten here.

Needs network access, which is why it is not part of `invoke
test-static`. Run it as `invoke check-pins`, or directly:

  python3 tests/check_pins.py
"""

import re
import sys
import urllib.request
from collections.abc import Callable
from functools import cache
from pathlib import Path

import yaml

ROOTS = ('roles', 'inventories')
RENOVATE = re.compile(r'#\s*renovate:.*\bdepName=(?P<dep>\S+)')
SHA256 = re.compile(r'^[0-9a-f]{64}$')


def fetch(url: str) -> str:
  """Return the body of a URL as text."""
  request = urllib.request.Request(url, headers={'User-Agent': 'check-pins'})
  with urllib.request.urlopen(request, timeout=60) as response:
    return response.read().decode()


def nextcloud(version: str) -> tuple[str, dict[str, str]]:
  """Return the `checksum` of the .tar.bz2 the role downloads."""
  url = (
    'https://download.nextcloud.com/server/releases/'
    f'nextcloud-{version}.tar.bz2.sha256'
  )
  return url, {'checksum': fetch(url).split()[0]}


def prometheus(version: str) -> tuple[str, dict[str, str]]:
  """Return one `checksums` entry per architecture, linux builds only."""
  url = (
    'https://github.com/prometheus/prometheus/releases/download/'
    f'v{version}/sha256sums.txt'
  )
  build = re.compile(
    rf'^(?P<sum>[0-9a-f]{{64}})\s+prometheus-{re.escape(version)}'
    r'\.linux-(?P<arch>\w+)\.tar\.gz$'
  )
  sums = {
    m['arch']: m['sum'] for m in map(build.match, fetch(url).splitlines()) if m
  }
  return url, {f'checksums.{arch}': value for arch, value in sums.items()}


# depName -> how to get the published checksums for a version, keyed
# by the path of the field they belong in.
UPSTREAM: dict[str, Callable[[str], tuple[str, dict[str, str]]]] = {
  'nextcloud/server': nextcloud,
  'prometheus/prometheus': prometheus,
}


@cache
def published(dep: str, version: str) -> tuple[str, dict[str, str]]:
  """Fetch the checksums for a version once, however often it is pinned."""
  return UPSTREAM[dep](version)


def mappings(node: yaml.Node):
  """Every mapping node in a composed document, depth first."""
  if isinstance(node, yaml.MappingNode):
    yield node
    for _, value in node.value:
      yield from mappings(value)
  elif isinstance(node, yaml.SequenceNode):
    for item in node.value:
      yield from mappings(item)


def pinned(mapping: yaml.MappingNode) -> dict[str, str]:
  """Return the checksum fields of a pin's mapping, flattened to paths."""
  found = {}
  for key, value in mapping.value:
    if key.value == 'checksum' and isinstance(value, yaml.ScalarNode):
      found['checksum'] = value.value.strip()
    elif key.value == 'checksums' and isinstance(value, yaml.MappingNode):
      for arch, digest in value.value:
        found[f'checksums.{arch.value}'] = str(digest.value).strip()
  return found


def pins(path: Path):
  """(line, dep, version, checksums) for every Renovate pin in a file."""
  text = path.read_text()
  comments = {
    number: match['dep']
    for number, line in enumerate(text.splitlines())
    if (match := RENOVATE.search(line))
  }
  if not comments:
    return
  # compose() rather than load(): it keeps line numbers, and leaves
  # `!vault` and other tags alone instead of failing on them.
  for document in yaml.compose_all(text, Loader=yaml.SafeLoader):
    for mapping in mappings(document):
      for key, value in mapping.value:
        line = key.start_mark.line
        if key.value == 'version' and line - 1 in comments:
          yield line + 1, comments[line - 1], value.value, pinned(mapping)


def check(path: Path, line: int, dep: str, version: str, found: dict) -> list:
  """Return what is wrong with one pin, or nothing."""
  where = f'{path}:{line} {dep} {version}'
  if dep not in UPSTREAM:
    return [
      f'{where}: has a checksum, but tests/check_pins.py cannot verify'
      ' it - add it to UPSTREAM'
    ]
  url, expected = published(dep, version)
  errors = [
    f'{where}: {field} is not a SHA-256'
    for field, value in found.items()
    if not SHA256.match(value)
  ]
  for field, value in sorted(expected.items()):
    if field not in found:
      continue  # an architecture the repo does not deploy
    if found[field] != value:
      errors.append(
        f'{where}: {field} is {found[field]}, upstream says {value} ({url})'
      )
  for field in sorted(set(found) - set(expected)):
    errors.append(f'{where}: {field} has no upstream checksum ({url})')
  return errors


def main() -> int:
  """Check every pin and report; non-zero exit on any problem."""
  checked, errors = 0, []
  for root in ROOTS:
    for path in sorted(Path(root).rglob('*.yml')):
      for line, dep, version, found in pins(path):
        if not found:
          continue  # an image or a tool: Renovate pins those whole
        checked += 1
        problems = check(path, line, dep, version, found)
        errors += problems
        if not problems:
          print(f'ok {path}:{line} {dep} {version}')
  for error in errors:
    print(f'FAIL {error}')
  print(f'{checked} pins with checksums checked, {len(errors)} problems.')
  if not checked:
    print('FAIL no pins found - has the comment format changed?')
    return 1
  return 1 if errors else 0


if __name__ == '__main__':
  sys.exit(main())
