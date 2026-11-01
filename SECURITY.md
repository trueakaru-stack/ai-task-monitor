# Security policy

## Supported version

Version 0.2.0 alpha is the only version currently under review. No public binary release is available yet.

## Reporting a vulnerability

After the public GitHub repository is created, report vulnerabilities through GitHub's private security-advisory form. Do not publish task data, local paths, credentials, or exploit details in a public issue.

## Security boundaries

- The application runs as the current user and does not require administrator rights.
- It does not download or execute remote code.
- The Claude Code integration modifies only the user's local hook configuration and preserves unrelated entries.
- The uninstaller is restricted to the expected per-user installation directory.
- Release artifacts must be built from tagged source, scanned, checksummed, and signed before publication.

