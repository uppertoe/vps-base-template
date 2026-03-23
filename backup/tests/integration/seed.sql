-- Seed data for backup/restore integration tests.
-- Loaded into the testapp database before tests run.

CREATE TABLE users (
  id   SERIAL PRIMARY KEY,
  name TEXT NOT NULL
);

INSERT INTO users (name) VALUES
  ('alice'),
  ('bob'),
  ('carol');
