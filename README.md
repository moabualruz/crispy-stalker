# crispy-stalker

Async Stalker/MAG portal API client.

## Status

Extracted from CrispyTivi. Intended as a reusable Rust client crate for legacy Stalker/MAG middleware portals.

## What This Crate Provides

- portal discovery
- MAC-based authentication/session handling
- typed access to:
  - genres/categories
  - channels
  - VOD items
  - series items
  - EPG data
- stream URL resolution helpers

## Installation

```toml
[dependencies]
crispy-stalker = "0.1"
```

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
# Ok(())
# }
```

## Primary Use Cases

- Stalker portal integration
- IPTV catalog sync
- stream URL resolution for MAG-style providers

## Relationship To Other Crates

- uses `crispy-iptv-types`
- often paired with downstream mapping layers and persistence code

## Caveats

- public docs should explain session expiry, retry semantics, and known provider-specific quirks before release
