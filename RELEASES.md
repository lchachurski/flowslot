# Release Process

## Creating a New Release

1. Update `VERSION` file with new version number (without `v` prefix):
   ```bash
   echo "1.1" > VERSION
   ```

2. Commit changes:
   ```bash
   git add -A
   git commit -m "chore: release v1.1"
   ```

3. Create annotated tag (with `v` prefix):
   ```bash
   git tag -a v1.1 -m "Release version 1.1"
   ```

4. Push to GitHub:
   ```bash
   git push origin main
   git push origin v1.1
   ```

## Versioning Scheme

- Format: `MAJOR.MINOR` (e.g., 1.0, 1.1, 2.0)
- **Major**: Breaking changes or significant rewrites
- **Minor**: New features, improvements, bug fixes

## Tag vs VERSION File

- **Tags**: Use `v` prefix (e.g., `v1.0`, `v1.1`)
- **VERSION file**: No prefix (e.g., `1.0`, `1.1`)
- The tag is the source of truth for releases

