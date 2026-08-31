-- Run ONCE in the Supabase SQL editor as an admin (the vault role cannot
-- create itself). Generate the password, then store the full connection
-- string in 1Password as mcp-token-vault/credentials/db_url.

CREATE ROLE token_vault LOGIN PASSWORD 'set-a-real-password-here';

GRANT USAGE ON SCHEMA public TO token_vault;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO token_vault;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO token_vault;
