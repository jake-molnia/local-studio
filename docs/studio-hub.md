# Studio Hub private alpha

## Objective

Studio Hub makes one owner's Local Studio projects and Pi sessions available from multiple browsers and desktop applications while every Pi runtime continues to execute beside its owning workspace.

The private alpha proves one durable path: enroll desktops, publish their projects, create a desktop-affine session, submit and cancel turns through the Hub, persist streamed Pi events, and reconnect clients without losing accepted output.

## Ownership

The Hub owns:

- owner and device authentication;
- the desktop registry and presence leases;
- logical projects and immutable desktop ownership;
- Hub session identifiers, titles, status, and archive state;
- command idempotency and the one-active-turn session invariant;
- the durable event journal and browser fan-out;
- protocol compatibility and database migrations.

The desktop owns:

- Pi execution and Pi-native JSONL sessions;
- workspace validation and availability;
- filesystem, Git, terminal, browser, connector, and provider operations;
- local controller and inference lifecycle;
- credentials used by local capabilities;
- a durable command receipt ledger and unacknowledged event outbox.

The Hub stores sanitized capability and controller metadata, not desktop provider or controller credentials.

## Topology

```text
Browser or packaged renderer
          |
          | owner-authenticated HTTP and SSE
          v
Studio Hub (Bun, Hono, SQLite)
          |
          | device-authenticated command SSE and event POSTs
          v
Desktop bridge
          |
          | loopback HTTP and SSE
          v
Existing agent runtime -> Pi -> local workspace
```

The loopback runtime is a private desktop implementation detail. It is not the distributed source of truth and is not exposed to the Hub network.

## Protocol decisions

- Protocol version 1 is transport-neutral even though the private alpha uses command SSE and event HTTP POSTs.
- Enrollment exchanges a one-time operator token for a revocable random device credential.
- Owner and device credentials are separate and are never accepted by the other authorization boundary.
- Commands use Hub-generated UUIDs and are persisted before delivery.
- A desktop records a command before execution and returns its previous result when the same command is delivered again.
- Desktop events use a persistent stream identifier and a monotonically increasing sequence.
- The Hub acknowledges the highest contiguous sequence it has committed for that stream.
- A desktop removes outbox events only after acknowledgement.
- Browser event cursors are Hub database event identifiers and do not reuse Pi's resettable runtime sequence.
- One command that mutates a session may be active at a time. Conflicting turn submissions fail clearly instead of entering an implicit distributed queue.
- If the Hub disconnects, an accepted local turn continues and its events remain in the desktop outbox. No new Hub session mutation executes until connectivity returns.
- If a desktop is offline, history remains readable and new execution is rejected.
- Sessions never migrate between desktops in protocol version 1.

## Migration

Hub mode is opt-in. Existing local-only sessions and projects continue to work unchanged.

On first connection, a desktop publishes its current project inventory. Importing existing Pi transcripts is nondestructive and can be added after the live vertical slice; the native JSONL files remain the resume source even after their renderable events are present in the Hub journal.

## Private-alpha scope

In scope:

- one owner;
- multiple trusted desktops and browser clients;
- desktop enrollment and revocation-ready credentials;
- desktop presence and project publication;
- desktop-affine Hub sessions;
- prompt submission, cancellation, command acknowledgement, and errors;
- durable Hub event history and live multi-client streaming;
- Hub and desktop reconnection;
- a browser acceptance surface;
- private deployment behind Tailscale or an equivalent authenticated network.

Explicitly deferred:

- cloud or headless Pi workers;
- teams, roles, organizations, and public sharing;
- offline turn queues;
- session migration, failover, workspace synchronization, and cloning;
- distributed automations or scheduling;
- remote terminal and embedded-browser control;
- full Configure, Usage, and inference lifecycle federation;
- central storage of desktop provider or controller secrets.

## Acceptance

The private-alpha vertical slice is accepted when manual validation on real local processes demonstrates:

1. a desktop enrolls and reconnects with its stored credential;
2. the Hub reports its presence and published projects;
3. a browser creates a session for one project and submits a Pi turn;
4. two event clients receive the same ordered output;
5. reloading a client reconstructs the persisted history;
6. duplicate command delivery does not duplicate a turn;
7. a Hub restart preserves projects, sessions, commands, and events;
8. a temporary Hub outage does not lose events from an accepted desktop turn;
9. an offline desktop causes a clear execution conflict;
10. repository validation completes with `npm run check`.

The repository does not add automated test code for these scenarios. They are exercised as hands-on acceptance flows against the running Hub, agent runtime, frontend, and packaged desktop as appropriate.
