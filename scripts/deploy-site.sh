#!/bin/sh
# Deploy the reclaimac.com marketing site.
# It's a Cloudflare Worker with static assets (config: ../wrangler.toml,
# [assets] directory = ./docs). Two CF accounts are on this login, so the
# account is pinned here to Clayton's.
cd "$(dirname "$0")/.." || exit 1
CLOUDFLARE_ACCOUNT_ID=305ab75281717568c5612a2abcbc696e exec npx wrangler deploy
