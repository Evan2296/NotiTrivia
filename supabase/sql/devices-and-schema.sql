-- Devices table: one row per installed app
create table devices (
  id uuid default gen_random_uuid() primary key,
  device_token text not null unique,
  timezone text not null default 'America/New_York',
  created_at timestamptz default now(),
  last_seen timestamptz default now()
);

-- Questions table: your 14k question bank
create table questions (
  id text primary key,
  question text not null,
  choices text[] not null,
  correct text not null,
  type text not null,
  times_used integer default 0
);

-- Index so we can efficiently pull least-used questions
create index on questions (times_used);