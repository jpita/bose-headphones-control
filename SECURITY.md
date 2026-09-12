# Security Policy

## Supported versions

Security fixes are applied to the latest release and the `main` branch.

## Report a vulnerability

Please use GitHub's private **Report a vulnerability** option on the repository Security tab. Do not open a public issue for a vulnerability.

Include the affected version, operating system, reproduction steps, and expected impact. Reports involving the local HTTP API, Bluetooth commands, packaged applications, or dependency supply chain are in scope.

The app binds its HTTP service to the local machine by default. Exposing it on another network interface is unsupported and should only be done after reviewing the security implications.
