# crispy-stalker

Async Stalker/MAG portal API client.

## What This Crate Is

`crispy-stalker` targets legacy Stalker / MAG middleware portals. It handles portal discovery, MAC-based authentication, paginated content retrieval, and stream URL resolution in a reusable client crate.

## What It Provides

- `StalkerClient`
- `StalkerCredentials`
- `StalkerSession`
- typed models for channels, VOD, series, profile, and EPG entries
- stream URL resolution helpers
- retry/backoff support

## Installation

```toml
[dependencies]
crispy-stalker = "0.1.1"
```

MSRV: Rust `1.85`

## Quick Start

```rust
use crispy_stalker::{StalkerClient, StalkerCredentials};

# async fn demo() -> Result<(), Box<dyn std::error::Error>> {
let creds = StalkerCredentials {
    base_url: "http://portal.example.com".into(),
    mac_address: "00:1A:79:AB:CD:EF".into(),
    timezone: None,
};

let mut client = StalkerClient::new(creds, false)?;
client.authenticate().await?;

let _genres = client.get_genres().await?;
# Ok(())
# }
```

## Typical Uses

- Stalker portal integration
- channel/VOD sync jobs
- MAG stream URL resolution

## Current Limitations

- provider-side inconsistencies are common in Stalker ecosystems; callers should still expect some portals to diverge from the happy path
- no persistence layer
- no playback probing or media diagnostics

## License

See `LICENSE.md` and `NOTICE.md`.
