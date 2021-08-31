/*
    WALRUS:
        Write Ahead Log Realtime Unified Security
*/

create schema cdc;
grant usage on schema cdc to postgres;
grant usage on schema cdc to authenticated;


create or replace function cdc.get_schema_name(entity regclass)
returns text
immutable
language sql
as $$
    SELECT nspname::text
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS ns
      ON c.relnamespace = ns.oid
    WHERE c.oid = entity;
$$;


create or replace function cdc.get_table_name(entity regclass)
returns text
immutable
language sql
as $$
    SELECT c.relname::text
    FROM pg_catalog.pg_class AS c
    JOIN pg_catalog.pg_namespace AS ns
      ON c.relnamespace = ns.oid
    WHERE c.oid = entity;
$$;


create or replace function cdc.selectable_columns(
    entity regclass,
    role_ text default 'authenticated'
)
returns text[]
language sql
stable
as $$
/*
Returns a text array containing the column names in *entity* that *role_* has select access to
*/
    select 
        coalesce(
            array_agg(rcg.column_name order by c.ordinal_position),
            '{}'::text[]
        )
    from
        information_schema.role_column_grants rcg
        inner join information_schema.columns c
            on rcg.table_schema = c.table_schema
            and rcg.table_name = c.table_name
            and rcg.column_name = c.column_name
    where
        -- INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
        rcg.privilege_type = 'SELECT'
        and rcg.grantee = role_ 
        and rcg.table_schema = cdc.get_schema_name(entity)
        and rcg.table_name = cdc.get_table_name(entity);
$$;


create or replace function cdc.get_column_type(entity regclass, column_name text)
    returns regtype
    language sql
as $$
    select atttypid::regtype
    from pg_catalog.pg_attribute
    where attrelid = entity
    and attname = column_name
$$;


-- Subset from https://postgrest.org/en/v4.1/api.html#horizontal-filtering-rows
create type cdc.equality_op as enum(
    'eq', 'neq', 'lt', 'lte', 'gt', 'gte'
);

create type cdc.user_defined_filter as (
    column_name text,
    op cdc.equality_op,
    value text
);


create table cdc.subscription (
	-- Tracks which users are subscribed to each table
	id bigint not null generated always as identity,
	user_id uuid not null references auth.users(id),
	entity regclass not null,
    -- Format. Equality only {"col_1": "1", "col_2": 4 }
	filters cdc.user_defined_filter[],
    constraint pk_subscription primary key (id),
    created_at timestamp not null default timezone('utc', now())
);

create function cdc.subscription_check_filters()
    returns trigger
    language plpgsql
as $$
/*
Validates that the user defined filters for a subscription:
- refer to valid columns that "authenticated" may access
- values are coercable to the correct column type
*/
declare
    col_names text[] = cdc.selectable_columns(new.entity);
    filter cdc.user_defined_filter;
    col_type text;
begin
    for filter in select * from unnest(new.filters) loop
        -- Filtered column is valid
        if not filter.column_name = any(col_names) then
            raise exception 'invalid column for filter %', filter.column_name;
        end if;

        -- Type is sanitized and safe for string interpolation
        col_type = (cdc.get_column_type(new.entity, filter.column_name))::text;
        if col_type is null then
            raise exception 'failed to lookup type for column %', filter.column_name;
        end if;

        -- raises an exception if value is not coercable to type
        perform format('select %s::%I', filter.value, col_type);
    end loop;

    return new;
end;
$$;

create trigger tr_check_filters
    before insert or update on cdc.subscription
    for each row
    execute function cdc.subscription_check_filters();


grant all on cdc.subscription to postgres;
grant select on cdc.subscription to authenticated;


create or replace function  cdc.is_rls_enabled(entity regclass)
    returns boolean
    stable
    language sql
as $$
/*
Is Row Level Security enabled for the entity
*/
    select
        relrowsecurity
    from
        pg_class
    where
        oid = entity;
$$;



create or replace function cdc.cast_to_array_text(arr jsonb)
    returns text[]
    language 'sql'
    stable
as $$
/*
Cast an jsonb array of text to a native postgres array of text

Example:
    select cdc.cast_to_array_text('{"hello", "world"}'::jsonb)
*/
    select
        array_agg(xyz.v)
    from
        jsonb_array_elements_text(
            case
                when jsonb_typeof(arr) = 'array' then arr
                else '[]'::jsonb
            end
        ) xyz(v)
$$;

create or replace function cdc.cast_to_jsonb_array_text(arr text[])
    returns jsonb
    language 'sql'
    stable
as $$
/*
Cast an jsonb array of text to a native postgres array of text

Example:
    select cdc.cast_to_jsonb_array_text('{"hello", "world"}'::text[])
*/
    select
        coalesce(jsonb_agg(xyz.v), '{}'::jsonb)
    from
        unnest(arr) xyz(v);
$$;


create or replace function cdc.random_slug(n_chars int default 10)
    returns text
    language sql
    volatile
as $$
/*
Random string of *n_chars* length that is valid as a sql identifier without quoting
*/
  select string_agg(chr((ascii('a') + round(random() * 25))::int), '') from generate_series(1, n_chars)
$$;


create or replace function cdc.check_equality_op(
	op cdc.equality_op,
	type_ regtype,
	val_1 text,
	val_2 text
)
	returns bool
	immutable
	language plpgsql
as $$
/*
Casts *val_1* and *val_2* as type *type_* and check the *op* condition for truthiness
*/
declare
	op_symbol text = (
		case
			when op = 'eq' then '='
			when op = 'neq' then '!='
			when op = 'lt' then '<'
			when op = 'lte' then '<='
			when op = 'gt' then '>'
			when op = 'gte' then '>='
			else 'UNKNOWN OP'
		end
	);
	res boolean;
begin
	execute format('select %L::'|| type_::text || ' ' || op_symbol || ' %L::'|| type_::text, val_1, val_2) into res;
	return res;
end;
$$;


create type cdc.kind as enum('insert', 'update', 'delete');

create type cdc.wal_column as (
    name text,
    type text,
    value text,
    is_pkey boolean
);

create or replace function cdc.build_prepared_statement_sql(
    prepared_statement_name text,
	entity regclass,
	columns cdc.wal_column[]
)
    returns text
    language sql
as $$
/*
Builds a sql string that, if executed, creates a prepared statement to 
tests retrive a row from *entity* by its primary key columns.

Example
    select cdc.build_prepared_statment_sql('public.notes', '{"id"}'::text[], '{"bigint"}'::text[])
*/
	select
'prepare ' || prepared_statement_name || ' as
select
	count(*) > 0
from
	' || entity || '
where
	' || string_agg(quote_ident(pkc.name) || '=' || quote_nullable(pkc.value) , ' and ') || ';'
	from
		unnest(columns) pkc
	where
        pkc.is_pkey
	group by
		entity
$$;



create type cdc.wal_rls as (
    wal jsonb,
    is_rls_enabled boolean,
    users uuid[],
    errors text[]
);


create or replace function cdc.apply_rls(wal jsonb)
    returns cdc.wal_rls 
    language plpgsql
    volatile
as $$
/*
Append keys describing user visibility to each change

"security": {
    "visible_to": ["31b93c49-5435-42bf-97c4-375f207824d4"],
    "is_rls_enabled": true,
}

Example *change:
{
    "change": [
        {
            "pk": [
                {
                    "name": "id",
                    "type": "bigint"
                }
            ],
            "table": "notes",
            "action": "I",
            "schema": "public",
            "columns": [
                {
                    "name": "id",
                    "type": "bigint",
                    "value": 28
                },
                {
                    "name": "user_id",
                    "type": "uuid",
                    "value": "31b93c49-5435-42bf-97c4-375f207824d4"
                },
                {
                    "name": "body",
                    "type": "text",
                    "value": "take out the trash"
                }
            ],
            
        }
    ]
}
*/
declare
    -- Regclass of the table e.g. public.notes
	entity_ regclass = (quote_ident(wal ->> 'schema')|| '.' || quote_ident(wal ->> 'table'))::regclass;

    -- I, U, D, T: insert, update ...
    action char;

    -- Check if RLS is enabled for the table
    is_rls_enabled bool = cdc.is_rls_enabled(entity_);
	
	-- UUIDs of subscribed users who may view the change
	visible_to_user_ids uuid[] = '{}';

    -- Which columns does the "authenticated" role have permission to select (view)
    selectable_columns text[] = cdc.selectable_columns(entity_);
	
    -- role and search path at time function is called
    prev_role text = current_setting('role');
    prev_search_path text = current_setting('search_path');

    columns cdc.wal_column[] = 
        array_agg(
            (
                x->>'name',
                x->>'type',
                x->>'value',
                (pks ->> 'name') is not null
            )::cdc.wal_column
            order by (x->'position')::int asc
        )
        from
            jsonb_array_elements(wal -> 'columns') x
            left join jsonb_array_elements(wal -> 'pk') pks
                on (x ->> 'name') = (pks ->> 'name');

    errors text[] = '{}';

    -- Internal state tracking 
	user_id uuid;
	user_has_access bool;

    filters cdc.user_defined_filter[];
    allowed_by_filters boolean;

    prep_stmt_sql text;
begin
    -- Without nulling out search path, casting a table prefixed with a schema that is
    -- contained in the search path will cause the schema to be omitted.
    -- e.g. 'public.post'::reglcass:text -> 'post' (vs 'public.post')
    perform (
        set_config('search_path', '', true)
    );

    -- Collect sql string for prepared statment
    -- SQL string that will create a prepared statement to look up current *entity_* using primary key
    prep_stmt_sql = cdc.build_prepared_statement_sql('walrus_rls_stmt', entity_, columns);
    execute prep_stmt_sql;

    -- Set role to "authenticated" outside of hot loop because calls to set_config are expensive
    perform set_config('role', 'authenticated', true);

    -- For each subscribed user
    for user_id, filters  in select sub.user_id, sub.filters from cdc.subscription sub where sub.entity = entity_
    loop
        
        -- Check if the user defined filters exclude the current record 
        allowed_by_filters = true;

        if array_length(filters, 1) > 0 then
            select 
                -- Default to allowed when no filters present
                coalesce(
                    sum(
                        cdc.check_equality_op(
                            op:=f.op,
                            type_:=col.type::regtype,
                            val_1:=col.value,
                            val_2:=f.value
                        )::int
                    ) = count(1),
                    true
                )
            from 
                unnest(filters) f
                join unnest(columns) col
                    on f.column_name = col.name
            into allowed_by_filters;
        end if;

        -- If the user defined filters did not exclude the record
        if allowed_by_filters then

            -- Check if the user has access
            if is_rls_enabled then
                -- Impersonate the current user
                --perform cdc.impersonate(user_id);
                perform set_config('request.jwt.claim.sub', user_id::text, true);
                -- Lookup record by primary key while impersonating *user_id*
                execute 'execute walrus_rls_stmt' into user_has_access;
            else
                user_has_access = true;
            end if;

            if user_has_access then
                visible_to_user_ids = visible_to_user_ids || user_id;
            end if;
        end if;

    end loop;

    -- Delete the prepared statemetn
    deallocate walrus_rls_stmt;

    -- If the "authenticated" role does not have permission to see all columns in the table
    if array_length(selectable_columns, 1) < array_length(columns, 1) then

        -- Filter the columns to only the ones that are visible to "authenticated"
        wal = wal || (
            select
                jsonb_build_object(
                    'columns',
                    jsonb_agg(col_doc)
                )
            from
                jsonb_array_elements(wal -> 'columns') r(col_doc)
            where
                (col_doc ->> 'name') = any(selectable_columns)
        );
    end if;
    
    -- Restore previous configuration
    perform (
        set_config('request.jwt.claim.sub', null, true),
        set_config('role', prev_role, true),
        set_config('search_path', prev_search_path, true)
    );
    
    -- return the change object without primary key info 
	return (
        (wal #- '{pk}'),
        is_rls_enabled,
        visible_to_user_ids,
        errors
    )::cdc.wal_rls;
	
end;
$$;
