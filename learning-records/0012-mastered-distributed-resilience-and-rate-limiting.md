# Mastered Distributed Resilience and Rate-Limiting

The user progressed into systems resilience and ingestion safety, establishing key principles for building scrapers and background pollers that prevent WAF bans, manage process heap garbage collection, and avoid synchronized retry storms.

## Evidence
- Scored 100% correct answers on Lesson 0009 interactive verification checkpoint questions.

## Key Insights
- **Ephemeral Task Isolation:** Running heavy network fetching and XML/JSON parsing inside `Task.Supervisor.async_nolink` ensures reference-counted binary heaps (`refc` binaries) are reclaimed immediately upon process termination, safeguarding long-lived GenServers from silent memory leaks.
- **Conditional GET Validation:** Preserving ETags and Last-Modified timestamps allows upstream servers to respond with `304 Not Modified`, skipping body transfer and parsing entirely.
- **Differentiated HTTP Backoff:** Distinguishing between HTTP 403 (quarantine cooldown of 30m+ against WAF IP blacklisting) and HTTP 429 (exponential backoff respecting `Retry-After`).
- **Decorrelated Jitter:** Introducing randomized variance into backoff durations prevents synchronized retry waves (thundering herds) against external APIs.
