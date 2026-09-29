ci:
    bash tests/runner-contract.test.sh
    cargo fmt --check
    cargo clippy --all-targets --all-features -- -D warnings
    cargo test --all-features
    cargo doc --no-deps
    cargo package
