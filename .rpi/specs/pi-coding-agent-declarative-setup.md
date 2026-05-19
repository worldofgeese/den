---
domain: pi-coding-agent-declarative-setup
feature: pi-mps-declarative
last_updated: 2026-05-16T09:56:02+02:00
updated_by: .rpi/designs/2026-05-16-pi-coding-agent-declarative-setup.md
---

# Pi Coding Agent Declarative Setup

## Purpose

Declaratively install and configure the Pi coding agent CLI via Nix Home Manager so it connects to the Anthropic proxy with secrets retrieved from gopass at runtime.

## Scenarios

### Pi binary is available after home-manager switch
Given the shared-devtools aspect includes `pi-coding-agent`
When the user runs `home-manager switch`
Then `pi --version` succeeds and prints a version string

### Pi lists the Anthropic proxy provider
Given `~/.pi/agent/models.json` is managed by Home Manager with the anthropic-proxy provider
When the user runs `pi` and executes `/models`
Then the Opus, Sonnet, and Haiku models appear in the model picker

### Pi resolves the API key from gopass at request time
Given `models.json` uses `!gopass show -o dev/anthropic-proxy-key` for the apiKey
When the user sends a message to Pi using an Anthropic proxy model
Then Pi executes the gopass command, retrieves the key, and authenticates successfully against the proxy

### Pi sends requests to the correct proxy endpoint
Given the provider baseUrl is the Anthropic proxy's `/anthropic` path
When Pi makes an API call using the `anthropic-messages` API type
Then the request is sent to the proxy's `/anthropic/v1/messages` path

### Pi includes the api-key header
Given `models.json` specifies `headers.api-key` with the gopass command
When Pi makes an API call
Then the HTTP request includes an `api-key` header with the proxy credential value

### Home Manager switch does not embed secrets in the Nix store
Given the models.json uses `!command` syntax for secrets
When `home-manager switch` builds the configuration
Then the Nix store path for models.json contains the literal string `!gopass show -o dev/anthropic-proxy-key`, not the actual secret

### Pi works on both Linux and macOS hosts
Given `pi-coding-agent` is in `shared-devtools.nix` (shared between mahakala and M-02877)
When either host runs `home-manager switch`
Then Pi is installed and models.json is deployed on both platforms

## Constraints
- The API key must never appear in the Nix store or git history
- Pi's `baseUrl` must NOT include `/v1` (Pi appends it for `anthropic-messages` API type)
- The gopass entry `dev/anthropic-proxy-key` must exist before Pi can authenticate
- The GPG agent must be running for gopass to decrypt

## Out of Scope
- Claude Code or OpenCode proxy configuration changes
- Pi extensions, skills, themes, or settings.json customization
- Guix packaging of Pi
- Migrating OpenCode's hardcoded key to gopass
- Naming or referencing the employer
