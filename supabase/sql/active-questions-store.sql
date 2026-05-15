create table active_questions (
  slot text primary key,
  question_id text not null,
  correct_answer text not null,
  question_text text not null,
  delivered_at timestamptz not null,
  expiration_sent boolean default false
);