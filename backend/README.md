# Backend

The backend is provider-neutral JavaScript for Node 20+. It contains conservative
manga/chapter matching, source health and per-chapter fallback, shared scheduled
updates, rate limiting, SSRF-safe image fetch policy, Firebase/App Check
authorization, server-side account deletion, and appAccess administration.

A scheduler calls MangaUpdater.runDue. The injected store owns transactions for
canonical chapters, merge audit, shared follower counts, source health, and job
leases. One canonical tracked job serves all followers.

Install dependencies with npm install, run npm test, and deploy with Application
Default Credentials or workload identity. Do not use a project-owner service
account. The HTTP process binds to loopback by default; a deployment adapter may
place it behind an authenticated ingress.

