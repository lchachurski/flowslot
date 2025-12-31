# Release Process

## Creating a New Release

1. Update `VERSION` file with new version number (without `v` prefix):
   ```bash
   echo "2.1.0" > VERSION
   ```

2. Update `CHANGELOG.md` with release notes

3. Commit changes:
   ```bash
   git add -A
   git commit -m "chore: release v2.1.0"
   ```

4. Create tag (with `v` prefix):
   ```bash
   git tag v2.1.0
   ```

5. Update `latest` tag to point to this release:
   ```bash
   git tag -f latest v2.1.0
   ```

6. Push to GitHub:
   ```bash
   git push origin main
   git push origin v2.1.0
   git push origin latest --force
   ```

## Versioning Scheme

Format: `MAJOR.MINOR.PATCH` (e.g., 1.0.0, 1.1.0, 2.0.0)

- **X.y.z (Major)**: Breaking changes that require user action
- **x.Y.z (Minor)**: New features, backward compatible
- **x.y.Z (Patch)**: Bug fixes, backward compatible

## Tag vs VERSION File

- **Tags**: Use `v` prefix (e.g., `v2.0.0`, `v2.1.0`)
- **VERSION file**: No prefix (e.g., `2.0.0`, `2.1.0`)
- The tag is the source of truth for releases

