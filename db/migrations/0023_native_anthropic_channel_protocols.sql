do $$
declare
  constraint_name text;
begin
  select c.conname
    into constraint_name
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = current_schema()
     and t.relname = 'channels'
     and c.contype = 'c'
     and pg_get_constraintdef(c.oid) like '%protocol_mode%'
   limit 1;

  if constraint_name is not null then
    execute format('alter table channels drop constraint %I', constraint_name);
  end if;

  alter table channels
    add constraint channels_protocol_mode_check
    check (
      protocol_mode in (
        'openai_compatible',
        'native_proxy',
        'adapter_transform',
        'gemini',
        'gemini_generate_content',
        'anthropic',
        'anthropic_messages',
        'claude_compatible'
      )
    );
end $$;
