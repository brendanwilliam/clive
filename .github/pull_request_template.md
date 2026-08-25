## Summary

<!-- What changes, and why? Link the issue with Closes #123 when appropriate. -->

## Impact

- User-visible impact:
- Compatibility or migration impact:

## Security

<!-- Address pairing, certificate validation, storage, logging, permissions, CloudKit, cellular routing, and LAN exposure. Write "None" when none apply. -->

## Verification

- [ ] `./scripts/verify-local.sh`
- [ ] `./scripts/test-macos-integration.sh`
- [ ] Additional tests are listed below.

## UI feature map

- [ ] `docs/ui-feature-map.json` updates every affected component mapping, or appends one
      validated `no-component-impact` review record whose paths match the complete PR diff.
- [ ] `python3 scripts/feature-map.py validate` and
      `python3 scripts/feature-map.py check-change --base <develop-base>` pass.

## Screenshots

<!-- Required for UI changes. Use sanitized sample data. -->

## Checklist

- [ ] Tests cover behavioral changes.
- [ ] Documentation is updated.
- [ ] No secrets, pairing material, hostnames, fingerprints, or terminal contents are included.
- [ ] The linked issue and release-note impact are identified.
