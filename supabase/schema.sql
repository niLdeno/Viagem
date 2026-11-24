-- Travel to Euro 2027 — banco de dados do painel
-- Rode uma vez em: Supabase > SQL Editor > New query > colar tudo > Run

-- 1) Quem pode acessar: só e-mails cadastrados aqui leem e gravam dados
create table if not exists public.membros (
  email     text primary key check (email = lower(email)),
  criado_em timestamptz not null default now()
);
alter table public.membros enable row level security; -- sem políticas: invisível pela API

create or replace function public.e_membro()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.membros
    where email = lower(coalesce(auth.jwt() ->> 'email', ''))
  )
$$;
revoke all on function public.e_membro() from public, anon;
grant execute on function public.e_membro() to authenticated;

-- 2) Tabelas do painel
create table if not exists public.cfg (
  id            text primary key default 'main',
  dados         jsonb not null default '{}',
  atualizado_em timestamptz not null default now()
);

create table if not exists public.cambio (
  id        uuid primary key default gen_random_uuid(),
  data      date not null default current_date,
  comercial numeric(10,4) not null,
  turismo   numeric(10,4),
  fonte     text,
  criado_em timestamptz not null default now()
);

create table if not exists public.voos (
  id        uuid primary key default gen_random_uuid(),
  data      date not null default current_date,
  rota      text not null,
  cia       text,
  preco     numeric(12,2) not null,
  datas     text,
  origem    text not null default 'manual' check (origem in ('manual','monitor')),
  link      text,
  obs       text,
  criado_em timestamptz not null default now()
);

create table if not exists public.alertas (
  id        uuid primary key default gen_random_uuid(),
  data      date not null default current_date,
  texto     text not null,
  lido      boolean not null default false,
  criado_em timestamptz not null default now()
);

create table if not exists public.gastos (
  id        uuid primary key default gen_random_uuid(),
  data      date not null default current_date,
  descricao text not null,
  cat       text not null,
  valor     numeric(12,2) not null,
  moeda     text not null default 'BRL' check (moeda in ('BRL','EUR')),
  taxa      numeric(10,4) not null default 0,
  status    text not null default 'pago' check (status in ('pago','reservado')),
  criado_em timestamptz not null default now()
);

create table if not exists public.depositos (
  id        uuid primary key default gen_random_uuid(),
  data      date not null default current_date,
  valor     numeric(12,2) not null,
  nota      text,
  criado_em timestamptz not null default now()
);

create table if not exists public.euros (
  id            uuid primary key default gen_random_uuid(),
  data          date not null default current_date,
  eur           numeric(12,2) not null,
  taxa          numeric(10,4) not null,
  onde          text,
  comercial_dia numeric(10,4),
  criado_em     timestamptz not null default now()
);

create table if not exists public.tarefas (
  id        uuid primary key default gen_random_uuid(),
  txt       text not null,
  feito     boolean not null default false,
  ordem     bigint not null default 0,
  criado_em timestamptz not null default now()
);

-- 3) Segurança (RLS), permissões e atualização em tempo real
do $$
declare t text;
begin
  foreach t in array array['cfg','cambio','voos','alertas','gastos','depositos','euros','tarefas'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists membros_tudo on public.%I', t);
    execute format('create policy membros_tudo on public.%I for all to authenticated
                    using ((select public.e_membro())) with check ((select public.e_membro()))', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- 4) Membros autorizados: troque pelos e-mails da família antes de rodar
--    (os e-mails reais ficam só no banco, não neste arquivo público)
insert into public.membros (email) values
  ('primeiro.email@exemplo.com')
  -- , ('segundo.email@exemplo.com')
on conflict do nothing;

-- 5) Ajustes iniciais da viagem (editáveis depois no painel)
insert into public.cfg (id, dados) values ('main', '{"origem":"FOR","destinos":"Lisboa, Madri, Paris","adultos":2}')
on conflict (id) do nothing;

-- 6) Ajustes para o monitor diário (aplicado em 24/11/2026)
alter table public.cambio add constraint cambio_data_unica unique (data);
alter table public.alertas add column if not exists tipo text check (tipo in ('euro','voo','promo'));

-- 7) Ofertas de euro por casa/banco (melhor lugar para comprar), comparadas pelo VET
create table if not exists public.ofertas_euro (
  id         uuid primary key default gen_random_uuid(),
  data       date not null default current_date,
  fornecedor text not null,
  tipo       text not null check (tipo in ('conta global','especie','cartao pre-pago','remessa')),
  vet        numeric(10,4) not null check (vet > 0),   -- R$ por euro, custo final com IOF e tarifas
  cotacao    numeric(10,4),                            -- cotação anunciada, antes do IOF
  iof_pct    numeric(5,2),
  tarifa     text,
  link       text,
  obs        text,
  origem     text not null default 'monitor' check (origem in ('monitor','manual')),
  criado_em  timestamptz not null default now(),
  unique (data, fornecedor, tipo)
);
create index if not exists ofertas_euro_data_idx on public.ofertas_euro (data desc, vet);
alter table public.ofertas_euro enable row level security;
create policy membros_tudo on public.ofertas_euro for all to authenticated
  using ((select public.e_membro())) with check ((select public.e_membro()));
revoke all on public.ofertas_euro from anon;
grant select, insert, update, delete on public.ofertas_euro to authenticated;
alter publication supabase_realtime add table public.ofertas_euro;

-- 8) Checklist com prazo e prioridade
alter table public.tarefas add column if not exists prazo date;
alter table public.tarefas add column if not exists prioridade smallint not null default 2 check (prioridade between 1 and 3);
comment on column public.tarefas.prioridade is '1 = alta, 2 = média, 3 = baixa';

-- 9) Checklist simplificado: só data limite (prazo) e data de conclusão.
--    A coluna prioridade (seção 8) não é mais usada pela página.
alter table public.tarefas add column if not exists concluida_em timestamptz;
