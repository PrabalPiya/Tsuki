# Security

## Threat model

Assume an attacker has the entire repository, client binary, Firebase public
configuration, and knowledge of every API request. Security depends on identity,
authorization, validation, App Check, and IAM—not obscurity.

Production Firestore requires authentication plus appAccess. Shared canonical
data is client read-only. User documents are UID-owned and field-bounded.
Internal mappings, tracking, health, jobs, rankings writes, merge audit, and
follower state are inaccessible to clients. Emulator tests cover cross-user and
authoritative-write attacks.

The API verifies both Firebase ID and App Check tokens, rechecks appAccess,
limits UID and IP activity, bounds queries, exposes no arbitrary URL fetch, and
returns no stack traces. The URL policy rejects unsupported schemes, credentials,
loopback/private/link-local/metadata addresses, unapproved hosts, unsafe
redirects, oversized responses, and unexpected MIME.

Admin SDKs bypass Firestore rules. Deploy each worker with only the IAM roles it
needs. Prefer workload identity/short-lived credentials; never download a
project-wide key for routine production use.

## Secret handling

Never commit admin credentials, service-account JSON, signing material,
deployment credentials, private provider tokens, authorization headers, ID
tokens, refresh tokens, or App Check debug tokens. If committed, rotate the
credential; deleting a later revision is not remediation.

## Privacy

Local state is keyed by UID. Adult titles remain out of Discover even when
deliberate adult search is enabled. Do not include adult titles in analytics,
logs, crash reports, or lock-screen notifications.

## Responsible disclosure

Do not open a public exploit issue. Contact the repository owner through the
private security-reporting channel configured on the hosting platform. Include
impact, reproduction, affected revision, and suggested remediation.

