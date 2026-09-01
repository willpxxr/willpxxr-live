CREATE TABLE IF NOT EXISTS credentials (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider TEXT NOT NULL,
    principal TEXT NOT NULL DEFAULT 'default',
    kind TEXT NOT NULL CHECK (kind IN ('oauth', 'api_key')),
    access_token_enc BYTEA,
    refresh_token_enc BYTEA,
    expires_at TIMESTAMPTZ,
    scopes TEXT,
    rotated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (provider, principal)
);

CREATE INDEX IF NOT EXISTS credentials_expires_at_idx ON credentials (expires_at);
