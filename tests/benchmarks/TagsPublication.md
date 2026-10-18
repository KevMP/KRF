# Tags publication scaling benchmark

## Reproduce

Run `npm run measure:tags` from the repository root on Windows with the repository's Roblox Studio, Rojo and run-in-roblox tooling installed. Run Studio jobs serially: run-in-roblox temporarily installs a shared plugin. Results and launcher logs are written under `build/tags-scaling/<run-id>/`.

The standalone [benchmark](./TagsPublication.luau) runs in real Studio, without Jest or coverage instrumentation. Its timings include synchronous `TagController:AddTag` work through the selected observation boundary. One Actor has **1, 16, 64, 256, 1,024 or 4,096 distinct visible Tag IDs simultaneously active**, with one finite instance per ID. Each refresh touches only `Scale.Tag0001`, alternates its duration between 60 and 61 seconds, and uses the production synchronized clock. Automatic stepping is disabled to isolate mutation cost; no countdown work is timed.

For each size, three separate controller lifetimes measure:

- `Controller`: authoritative mutation with no replication observer.
- `Projection`: controller mutation plus the real adapter's synchronous aggregate update, with a counting callback. This deliberately excludes the adapter's full-map snapshot clone and all N3 work; it is **not** the complete adapter/publication path.
- `Publication`: controller mutation, adapter update and snapshot clone, then ordinary N3 event validation, canonical capture/diff, full-state measurement and commit observation. No publication stages are bypassed.

Static catalog/schema compilation, initial seeding/attachment and teardown are outside timing. Each mode/size has 32 warmups and three trials of 200 individually timed refreshes, yielding outside the timed interval every 20 samples. Each process therefore records 600 samples per mode/size. GC and scheduling variation can affect tails; elapsed microseconds are observations, not CI thresholds.

There are no N4 recipients, packet encoding/delivery or N5 client callbacks in these CPU measurements. They do not measure FPS, network latency, bandwidth, concurrent Actors, multi-domain transactions or large instance stacks. The separate native two-client fixture verifies actual startup, transports and consumer installation. Its initial baseline had two visible IDs and one private ID active, four instances total. Its authoritative mutation batch briefly reached five instances before removing one stack; clients received the final aggregate. It was not a scaling test.
