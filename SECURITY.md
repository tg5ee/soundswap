# Security Policy

## Supported Versions

SoundSwap is an open-source project under active development.

Security fixes are maintained on the latest version of the main branch. Older commits and unofficial builds are not actively supported.

SoundSwap has been reviewed for compatibility with Omarchy 4.0.4. Compatibility with future versions may change.

| Version | Supported          |
| ------- | ------------------ |
| v1.0    | :white_check_mark: |


## Reporting a Vulnerability

If you discover a potential security issue, please report it responsibly.

Use GitHub's Private Vulnerability Reporting feature under the repository's Security tab, if available.

If private reporting isn't available, open an issue requesting a private contact method without sharing sensitive details.

Include steps to reproduce the problem, affected versions, and any relevant logs.

Please avoid publicly disclosing exploitable vulnerabilities before a fix can be developed.

Security reports and responsible disclosures are appreciated.

## Security Practices

SoundSwap is designed to operate within the user's existing Omarchy environment without requiring root privileges.

Security considerations include:

Safe installation and uninstallation

Protection of existing user files and configurations

File permission and path validation

Symlink and path traversal safeguards

Input validation and safe command execution

Automated regression testing

Minimal dependencies and system modifications

Security improvements are tested before release whenever practical.

## Response and Fixes

SoundSwap is an independently maintained open-source project.

Security reports will be reviewed as time permits, with potentially harmful issues prioritized.

Confirmed vulnerabilities will be addressed as quickly as reasonably possible, and regression tests will be added where practical.

There is no guaranteed response or resolution timeframe.
