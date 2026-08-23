"""
python-invoke tasks
https://docs.pyinvoke.org/en/stable.

Collection of shell commands for ansible.
Acts as documentation of the command and
correct parameters as well as shorthand
for complex parameters.
"""

from pathlib import Path
from re import compile as re_compile
from shutil import rmtree, which
from tempfile import mkdtemp

from invoke import Exit, context, task

ANSIBLE_BIN = 'ansible'
ANSIBLE_PLAYBOOK_BIN = 'ansible-playbook'
ANSIBLE_LINT_BIN = 'ansible-lint'
YAMLLINT_BIN = 'yamllint'
RUFF_BIN = 'ruff'
ASCIIDOCTOR_BIN = 'asciidoctor'
# Converts Markdown to AsciiDoc, so the skill pages go through the
# same renderer as everything else rather than a second one.
KRAMDOC_BIN = 'kramdoc'
MOLECULE_BIN = 'molecule'
INVENTORY_DIR = 'inventories'
INVENTORY = f'{INVENTORY_DIR}/machines.yml'
# Groups in the inventory above. Every playbook is `hosts: all`, so
# these are what a run is narrowed to.
GROUP_PRODUCTION = 'production'
GROUP_TESTLAB = 'testlab'
# Fake, non-vaulted inventory used by the tests, so they run without
# the vault password. See doc/TESTING.adoc.
TEST_INVENTORY = f'{INVENTORY_DIR}/test/machines.yml'
TESTS_DIR = 'tests'
STATIC_TESTS = f'{TESTS_DIR}/static.yml'
ROLES_DIR = 'roles'
PLAYBOOKS_DIR = 'playbooks'
HOSTS_ALL = 'all'
LOG_DIR = 'log'
HOOKS_DIR = '.githooks'
# Every AsciiDoc page: doc/, README.adoc and
# .claude/CLAUDE.adoc alike.
DOCS_GLOB = '*.adoc'
# Rendered documentation. Named for what it holds rather than for the
# tool: `playbooks/site.yml` builds a *host*, and these two must not be
# confused when someone greps for "site".
DOCS_OUT_DIR = 'public'
DOCS_DIR = 'doc'
README = 'README.adoc'
SKILLS_DIR = '.claude/skills'
SKILLS_GLOB = '*/SKILL.md'
ATTRIBUTES_PAGE = 'doc/.attributes-page.adoc'
ASK_PASS = '--ask-pass'
ASK_BECOME_PASS = '--ask-become-pass'
VERBOSE = '-vvv'
CHECK = '--check'
DIFF = '--diff'


def ctx_run(
  ctx: context,
  cmd: list[str],
) -> None:
  """
  Boiler plate function to
  flatten the command list
  and run the command.
  """
  ctx.run(' '.join(cmd))


def check_remote_user(
  cmd: list[str],
  remote_user: str,
) -> None:
  """
  If not empty, run operations as this user.
  """
  if remote_user is not None:
    cmd.append(f'--user {remote_user}')


def check_ask_pass(
  cmd: list[str],
  ask_pass: bool,
) -> None:
  """
  If requested, append flag to
  ask for password.
  """
  if ask_pass:
    cmd.append(ASK_PASS)


def check_host(
  cmd: str,
  hosts: str,
) -> None:
  """
  If not empty, append hosts to command.
  """
  if hosts and hosts != HOSTS_ALL:
    cmd.append(f"--limit '{hosts}'")


def check_ask_become_pass(
  cmd: list[str],
  ask_become_pass: bool,
) -> None:
  """
  If requested, append flag for sudo password.
  """
  if ask_become_pass:
    cmd.append(ASK_BECOME_PASS)


def check_verbose(
  cmd: list[str],
  verbose: bool,
) -> None:
  """
  If requested, append verbose
  flag.
  """
  if verbose:
    cmd.append(VERBOSE)


def check_tags(
  cmd: list[str],
  tags: str,
) -> None:
  """
  If not empty, append tags to command.
  """
  if tags:
    cmd.append(f"--tags '{tags}'")


def run_linter(
  ctx: context,
  cmd: list[str],
) -> bool:
  """
  Run a single linter and report
  whether it passed.

  A missing linter counts as a failure:
  a silently skipped check is worse than
  a noisy one.
  """
  binary = cmd[0]
  if which(binary) is None:
    print(f'{binary}: not found, rebuild the Dev Container')
    return False

  return ctx.run(' '.join(cmd), warn=True).ok


def run_linters(
  ctx: context,
  cmds: list[list[str]],
) -> None:
  """
  Run every linter before failing, so that
  one run reports everything that needs
  fixing instead of stopping at the first
  problem.
  """
  failed = {cmd[0] for cmd in cmds if not run_linter(ctx, cmd)}
  if failed:
    raise Exit(f'Linting failed: {", ".join(sorted(failed))}', code=1)


def yaml_lint_cmds() -> list[list[str]]:
  """
  Commands to lint YAML style, configured
  via `.yamllint`.
  """
  return [
    [
      YAMLLINT_BIN,
      # Warnings are errors, nothing rots
      # into background noise.
      '--strict',
      '.',
    ],
  ]


def ansible_lint_cmds(
  fix: bool,
) -> list[list[str]]:
  """
  Commands to lint playbooks and roles,
  configured via `.ansible-lint`.
  """
  cmd: list[str] = [ANSIBLE_LINT_BIN]
  if fix:
    cmd.append('--fix')

  return [cmd]


def doc_files() -> list[str]:
  """
  Every AsciiDoc page in the repository, sorted
  so that a run reports them in a stable order.

  `doc/.attributes-page.adoc` is included rather
  than skipped for being a fragment: it parses
  standalone, so there is nothing to leave out
  and therefore no exclusion list to fall out of
  date.
  """
  return sorted(
    str(path) for path in Path('.').rglob(DOCS_GLOB) if '.git' not in path.parts
  )


def docs_lint_cmds() -> list[list[str]]:
  """
  Commands to check AsciiDoc structure via
  `asciidoctor`.

  One invocation for every page rather than one
  per page: asciidoctor reports the faults in
  all of its inputs before exiting, so a single
  run already names every broken page - the same
  property `run_linters` provides for the
  linters either side of this one.

  There is no `--fix` counterpart, so this takes
  no flag: nothing here can be repaired
  automatically.
  """
  files = doc_files()
  if not files:
    return []

  return [
    [
      ASCIIDOCTOR_BIN,
      # A warning that does not fail is a warning
      # nobody reads, which is the same stance as
      # `yamllint --strict` above. It is what
      # turns a dropped table cell, a missing
      # include or a skipped section level into a
      # failure. Note what it does not catch: an
      # unresolved cross-reference is rendered as
      # a dead link and reported nowhere - see
      # .devcontainer/Dockerfile.
      '--failure-level=WARN',
      # Rendered only to find faults. Publishing
      # the pages is separate work, tracked in
      # doc/TODO.adoc.
      '--out-file',
      '/dev/null',
      *files,
    ],
  ]


def python_lint_cmds(
  fix: bool,
) -> list[list[str]]:
  """
  Commands to lint and format-check Python,
  configured via `pyproject.toml`.
  """
  check: list[str] = [RUFF_BIN, 'check']
  fmt: list[str] = [RUFF_BIN, 'format']
  if fix:
    check.append('--fix')
  else:
    fmt.append('--check')

  return [check, fmt]


@task
def lint_yaml(
  ctx: context,
) -> None:
  """
  Lint YAML files via `yamllint`.
  """
  run_linters(ctx, yaml_lint_cmds())


@task
def lint_ansible(
  ctx: context,
  fix: bool = False,
) -> None:
  """
  Lint playbooks and roles via `ansible-lint`.
  """
  run_linters(ctx, ansible_lint_cmds(fix))


@task
def lint_python(
  ctx: context,
  fix: bool = False,
) -> None:
  """
  Lint and format-check Python via `ruff`.
  """
  run_linters(ctx, python_lint_cmds(fix))


@task
def lint_docs(
  ctx: context,
) -> None:
  """
  Check AsciiDoc structure via `asciidoctor`.
  """
  run_linters(ctx, docs_lint_cmds())


@task
def lint(
  ctx: context,
  fix: bool = False,
) -> None:
  """
  Run all linters.

  With `--fix`, apply the fixes the linters
  can make on their own instead of only
  reporting them. `lint-docs` has no such
  mode and runs unchanged either way.
  """
  run_linters(
    ctx,
    yaml_lint_cmds()
    + ansible_lint_cmds(fix)
    + python_lint_cmds(fix)
    + docs_lint_cmds(),
  )


def doc_pages() -> list[str]:
  """
  List the pages the rendered site is built from.

  `README.adoc` is the landing page and everything under `doc/` is a
  chapter. `.claude/CLAUDE.adoc` is deliberately absent: it is
  instructions for a tool rather than documentation of the host, and
  publishing it would put it in front of readers it is not written
  for.

  `doc/.attributes-page.adoc` is excluded explicitly. It is a fragment
  every page includes rather than a page of its own, and rendering it
  publishes an empty document. Note it has to be named rather than
  left to the glob: `Path.glob` matches a leading dot where a shell
  glob does not, which is exactly the sort of difference that ships a
  stray page.
  """
  return [README] + sorted(
    str(path)
    for path in Path(DOCS_DIR).glob(DOCS_GLOB)
    if not path.name.startswith('.')
  )


def rewrite_doc_links(
  root: Path,
) -> int:
  """
  Point the generated pages at each other.

  The sources link to `doc/TESTING.adoc` and friends, which is right
  where the source is read - GitHub renders those, so the repository
  browses correctly. It is wrong in the generated site, where the
  file beside it is `TESTING.html`.

  Rewriting the rendered HTML rather than the AsciiDoc is what keeps
  both readers working: an `xref:` with `outfilesuffix` would fix the
  site and break browsing the source. Only the `href` is touched, so
  a page that merely mentions a filename in prose is left alone.
  """
  pattern = re_compile(r'(href="[^"]*?)\.adoc(?=["#])')
  rewritten = 0
  for page in root.rglob('*.html'):
    before = page.read_text()
    after = pattern.sub(r'\1.html', before)
    if after != before:
      page.write_text(after)
      rewritten += 1

  return rewritten


def skill_pages() -> list[str]:
  """
  List the Markdown skill definitions that are published.

  These are the only Markdown in the repository, and they are included
  because the pages that *are* AsciiDoc lean on them - doc/TESTING.adoc
  alone points at `.claude/skills` ten times, so a reader of the
  rendered Testing page would otherwise meet references with nowhere
  to follow them to.
  """
  return sorted(str(path) for path in Path(SKILLS_DIR).glob(SKILLS_GLOB))


def render_skill(
  ctx: context,
  source: str,
  out_dir: Path,
) -> str:
  """
  Convert one Markdown skill to AsciiDoc and render it.

  Two steps rather than a Markdown renderer, deliberately. kramdoc
  produces AsciiDoc, which then goes through exactly the same
  asciidoctor call as every other page - so the skill pages get the
  same table of contents, the same highlighting and the same
  self-contained output, and there is one rendering path to keep
  correct rather than two.

  It also handles the YAML front matter, which is the part a Markdown
  renderer would get wrong: the keys become AsciiDoc attributes rather
  than leaking into the page as body text.

  What kramdoc does not produce is a document title, because the
  sources have no heading - they open with front matter and then
  prose. The title is synthesised from the skill's own name, and the
  shared attributes file is included so these pages match the rest.
  """
  name = Path(source).parent.name
  converted = Path(mkdtemp()) / f'{name}.adoc'
  ctx_run(ctx, [KRAMDOC_BIN, '--output', str(converted), source])

  # The include is written with an absolute path because this wrapper
  # lives in a temporary directory, nowhere near the repository.
  wrapped = converted.with_name(f'{name}-page.adoc')
  wrapped.write_text(
    f'= Skill: {name}\n'
    f'include::{Path(ATTRIBUTES_PAGE).resolve()}[]\n'
    f'{converted.read_text()}'
  )

  destination = out_dir / 'skills' / f'{name}.html'
  destination.parent.mkdir(parents=True, exist_ok=True)
  ctx_run(ctx, asciidoctor_cmd(str(wrapped), destination))
  rmtree(converted.parent, ignore_errors=True)

  return name


def asciidoctor_cmd(
  source: str,
  destination: Path,
) -> list[str]:
  """
  Build the asciidoctor invocation every page is rendered with.

  One helper rather than a literal in each caller, so the AsciiDoc
  pages and the converted Markdown ones cannot drift apart in how they
  are rendered.
  """
  return [
    ASCIIDOCTOR_BIN,
    # Warnings are errors here for the same reason `invoke lint-docs`
    # makes them so: a page that renders with a dropped table cell is
    # published looking finished.
    '--failure-level=WARN',
    # README includes LICENSE, every page includes the shared
    # attributes file, and the skill wrappers include it by absolute
    # path. The CLI defaults to unsafe already; naming it keeps the
    # build working if that ever changes.
    '--safe-mode',
    'unsafe',
    # The next three make the published pages self-contained, which
    # `:data-uri:` alone does not: it embeds images and leaves
    # stylesheets alone, so a default render links out to Google Fonts
    # and twice to cdnjs. That is three third parties between a reader
    # and a page about this host, in a repository that stops Grafana
    # phoning home on principle.
    #
    # rouge highlights server-side and embeds its CSS, where
    # highlight.js fetches a stylesheet and a script at read time.
    '-a',
    'source-highlighter=rouge',
    '-a',
    'webfonts!',
    # No page here uses an admonition, so `:icons: font` in the shared
    # attributes file buys nothing and costs a font-awesome stylesheet
    # from cdnjs. Overridden at build time rather than removed from the
    # source, so a NOTE added later still renders - as a text label
    # rather than an icon.
    '-a',
    'icons!',
    '--out-file',
    str(destination),
    source,
  ]


@task
def docs(
  ctx: context,
) -> None:
  """
  Render the AsciiDoc pages to a static site.

  Output goes to `public/`, which is what the Pages workflow
  publishes. Nothing here is committed - see `.gitignore`.
  """
  for binary in (ASCIIDOCTOR_BIN, KRAMDOC_BIN):
    if which(binary) is None:
      raise Exit(
        f'{binary}: not found, rebuild the Dev Container',
        code=1,
      )

  out = Path(DOCS_OUT_DIR)
  rmtree(out, ignore_errors=True)
  out.mkdir(parents=True)

  for page in doc_pages():
    # Each page keeps its path, so README's links to `doc/...` resolve
    # against the same layout in the output as in the source.
    destination = out / Path(page).with_suffix('.html')
    if page == README:
      destination = out / 'index.html'

    destination.parent.mkdir(parents=True, exist_ok=True)
    ctx_run(ctx, asciidoctor_cmd(page, destination))

  skills = [render_skill(ctx, page, out) for page in skill_pages()]
  rewritten = rewrite_doc_links(out)
  print(
    f'{DOCS_OUT_DIR}/: {len(doc_pages())} pages, '
    f'{len(skills)} skills, {rewritten} with rewritten links'
  )


@task
def install_hooks(
  ctx: context,
) -> None:
  """
  Enable the git hooks in `.githooks`.

  Hooks live in the repo but git only runs
  them once `core.hooksPath` points at them,
  which has to be done per clone.
  """
  cmd: list[str] = [
    'git',
    'config',
    'core.hooksPath',
    HOOKS_DIR,
  ]
  ctx_run(ctx, cmd)


@task
def login(
  ctx: context,
  host: str,
  remote_user: str = None,
) -> None:
  """
  Login to remote host via `ssh`.
  """
  user = ''
  if remote_user is not None:
    user = f'{remote_user}@'

  cmd: list[str] = [
    'ssh',
    f'{user}{host}',
  ]
  ctx_run(ctx, cmd)


@task
def clean(
  ctx: context,
) -> None:
  """
  Clear temporary/intermediate data.

  Clears:
  - log/*.log
  """
  cmd: list[str] = [
    'rm',
    '-rf',
    f'{LOG_DIR}/*.log',
  ]
  ctx_run(ctx, cmd)


@task(pre=[clean])
def ping(
  ctx: context,
  hosts: str = HOSTS_ALL,
  remote_user: str = None,
  ask_pass: bool = False,
  ask_become_pass: bool = False,
) -> None:
  """
  Ping host(s) via ansible.
  """
  cmd: list[str] = [
    f'{ANSIBLE_BIN}',
    '--module-name ping',
    f'--inventory {INVENTORY}',
    hosts,
  ]
  check_remote_user(cmd, remote_user)
  check_ask_pass(cmd, ask_pass)
  check_ask_become_pass(cmd, ask_become_pass)

  ctx_run(ctx, cmd)


@task(pre=[clean])
def run_playbook(
  ctx: context,
  playbook: str,
  hosts: str = None,
  remote_user: str = None,
  ask_pass: bool = False,
  ask_become_pass: bool = False,
  verbose: bool = False,
  tags: str = None,
) -> None:
  """
  Run a playbook on machines.

  `--hosts` is required and has no default. Every playbook is
  `hosts: all`, and the inventory holds both the production server
  and the disposable test machine, so a defaulted run would deploy
  to both. Pass a group (`production`, `testlab`) or a host name.
  """
  if not hosts:
    raise Exit(
      '--hosts is required: the inventory holds both '
      f'`{GROUP_PRODUCTION}` and `{GROUP_TESTLAB}` hosts, and every '
      'playbook targets `all`. Pass a group or a host name, e.g. '
      f'--hosts={GROUP_TESTLAB}.',
      code=1,
    )

  cmd: list[str] = [
    ANSIBLE_PLAYBOOK_BIN,
    playbook,
    f'--inventory {INVENTORY}',
    '--become',
  ]
  check_remote_user(cmd, remote_user)
  check_ask_pass(cmd, ask_pass)
  check_ask_become_pass(cmd, ask_become_pass)
  check_host(cmd, hosts)
  check_verbose(cmd, verbose)
  check_tags(cmd, tags)

  ctx_run(ctx, cmd)


def molecule_roles() -> list[str]:
  """
  Roles that carry a molecule scenario.

  Discovered rather than listed, so adding
  `roles/<role>/molecule/` is all it takes to
  include a new role.
  """
  roles = Path(ROLES_DIR).glob('*/molecule/*/molecule.yml')

  return sorted({path.parents[2].name for path in roles})


@task(pre=[clean])
def test_static(
  ctx: context,
  verbose: bool = False,
) -> None:
  """
  Run the static tests: no host is contacted.

  Validates every role's `meta/argument_specs.yml`
  and renders every template against
  `inventories/test`. Needs no vault password, so
  it also runs in CI.
  """
  cmd: list[str] = [
    ANSIBLE_PLAYBOOK_BIN,
    STATIC_TESTS,
    f'--inventory {TEST_INVENTORY}',
  ]
  check_verbose(cmd, verbose)

  ctx_run(ctx, cmd)


@task(pre=[clean], iterable=['role'])
def test_molecule(
  ctx: context,
  role: list[str] = None,
) -> None:
  """
  Run molecule scenarios in Docker containers.

  Without `--role`, every role that has a scenario
  is tested. Repeat `--role` to select several.
  Needs a working Docker daemon.
  """
  available = molecule_roles()
  if not available:
    raise Exit('No molecule scenarios found', code=1)

  selected = list(role) if role else available
  unknown = sorted(set(selected) - set(available))
  if unknown:
    raise Exit(
      f'No molecule scenario for: {", ".join(unknown)}. '
      f'Available: {", ".join(available)}',
      code=1,
    )

  failed: list[str] = []
  for name in selected:
    print(f'molecule: {name}')
    result = ctx.run(
      f'cd {ROLES_DIR}/{name} && {MOLECULE_BIN} test',
      warn=True,
    )
    if not result.ok:
      failed.append(name)

  if failed:
    raise Exit(f'Molecule failed for: {", ".join(failed)}', code=1)


@task(pre=[clean])
def test(
  ctx: context,
) -> None:
  """
  Run every automated test.

  Static tests first, since they are quick and
  need no container, then the molecule scenarios.

  Calls test_static/test_molecule as plain Python
  functions rather than invoke sub-tasks, so their
  own `pre=[clean]` does not fire a second time -
  this task's own `pre=[clean]` already covers it.
  """
  test_static(ctx)
  test_molecule(ctx)


@task(pre=[clean])
def check_drift(
  ctx: context,
  hosts: str = GROUP_PRODUCTION,
  playbook: str = None,
) -> None:
  """
  Report drift on the real hosts, changing nothing.

  Defaults to the `production` group: drift is a question about the
  server that is supposed to match the repository, whereas the test
  machine is expected to differ constantly.

  Runs the playbooks in `--check --diff` mode, so
  anything reported is a difference between the
  repository and the host - usually a manual change
  that was never written back.

  This needs the vault password and so cannot run
  in CI. Run it locally, e.g. weekly.

  Check mode is not perfect: tasks whose result
  depends on an earlier task having actually run
  are reported as changed or fail outright. Read
  the output, do not just look at the exit code.
  """
  playbooks = (
    [playbook]
    if playbook
    else sorted(str(path) for path in Path(PLAYBOOKS_DIR).glob('*.yml'))
  )

  drifted: list[str] = []
  for book in playbooks:
    print(f'check: {book}')
    cmd: list[str] = [
      ANSIBLE_PLAYBOOK_BIN,
      book,
      f'--inventory {INVENTORY}',
      '--become',
      CHECK,
      DIFF,
    ]
    check_host(cmd, hosts)
    if not ctx.run(' '.join(cmd), warn=True).ok:
      drifted.append(book)

  if drifted:
    raise Exit(
      'Check mode reported problems for: '
      f'{", ".join(drifted)}. See the output above; some tasks '
      'cannot run in check mode and fail for that reason alone.',
      code=1,
    )
