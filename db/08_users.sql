-- Real user accounts, one per person.
--   docker compose exec db psql -U depo -d depo -f /work/db/08_users.sql
--
-- Passwords are never stored. Only a PBKDF2 hash is kept, which cannot be
-- reversed - not even by you, and not by anyone who steals the database.

CREATE TABLE IF NOT EXISTS app_user (
  user_id       serial PRIMARY KEY,
  username      text NOT NULL UNIQUE,
  full_name     text NOT NULL,
  password_hash text NOT NULL,
  role          text NOT NULL CHECK (role IN ('staff','admin')),
  is_active     boolean NOT NULL DEFAULT true,
  must_change   boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text,
  last_login    timestamptz
);

-- Usernames are case-insensitive: JUAN and juan are the same person.
CREATE UNIQUE INDEX IF NOT EXISTS app_user_username_lower
  ON app_user (lower(username));

CREATE OR REPLACE VIEW v_users AS
SELECT user_id, username, full_name, role, is_active, must_change,
       created_at::date AS creado, created_by, last_login
FROM app_user
ORDER BY is_active DESC, role, username;
