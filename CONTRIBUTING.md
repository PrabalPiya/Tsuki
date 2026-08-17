# Contributing

Keep changes small, readable, and aligned with the product loop. Do not add
social features, ads, source choosers, recommendation feeds, giant genre
browsers, manual read/progress actions, or a Next Chapter button.

## Development

1. Install Flutter stable, Android SDK, Node 20+, and Firebase CLI.
2. Run Flutter formatting, analysis, and tests from app.
3. Run node --test from backend.
4. Run Firestore tests through the emulator.
5. Never point automated tests at production.

Feature code belongs under its feature directory. Shared models/configuration
belong in core only when multiple features use them. Prefer:

Screen → Riverpod controller/provider → repository → service

Provider changes must include capability documentation, parsing/validation
tests, failure behavior, rate limits, legal access basis, and attribution.
Security-sensitive changes must add a negative test.

Run formatters before opening a pull request. Explain behavior changes, risks,
and verification. Fork pull requests never receive production secrets or
deployment identities.

