alter table virtual_keys
  add column if not exists rate_limit_current_window_state jsonb not null default '{}'::jsonb;

alter table virtual_keys
  add constraint virtual_keys_rate_limit_current_window_state_object
  check (jsonb_typeof(rate_limit_current_window_state) = 'object')
  not valid;

alter table virtual_keys validate constraint virtual_keys_rate_limit_current_window_state_object;
