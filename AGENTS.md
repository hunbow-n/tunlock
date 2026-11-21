# Tunlock commit messages

Use Conventional Commits for new commits and for the final squash commit
that will land on `main`. Write the subject as `type(scope): description`
in English, with a short imperative description. The scope is optional.
Choose the type based on what changes for users.

| Type | Use | Release bump |
| --- | --- | --- |
| `fix:` | Fix behavior without breaking compatibility | Patch |
| `perf:` | Improve performance without breaking compatibility | Patch |
| `feat:` | Add a compatible feature | Minor |
| `docs:`, `test:`, `ci:`, `build:`, `refactor:`, `chore:`, `style:` | Maintain the project without a user-facing release | None |

Mark incompatible changes to the CLI, config, or MCP API with
`BREAKING CHANGE: <what breaks and how to migrate>` on one line in the
footer. You can also add `!` before the colon to flag the subject.
Breaking changes bump the minor version while Tunlock is on `0.x`
and the major version from `1.0.0` onward. Moving from `0.x` to `1.0.0` is
an explicit release decision.

## Examples

```text
fix(pf): clear stale states when the exit changes
feat(proxy): add saved proxy profiles
ci(release): verify the packaged checksum
```

```text
feat(config)!: replace EXPECTED_EGRESS with EXIT_IP

BREAKING CHANGE: Rename EXPECTED_EGRESS to EXIT_IP in tunlock.conf before upgrading.
```

See [release workflow and verification](docs/RELEASES.md).
