/*
meta-meta-generator

generates the source code for meta!

type
type_constructor_function

-- jsonb stuff
type_to_jsonb_comparator_function
type_to_jsonb_comparator_op
type_to_jsonb_type_constructor_function
type_to_jsonb_cast

-- view
relation
relation_create_stmt_function
create_relation_drop_stmt_create_function

-- view triggers
relation_insert_trigger_function
relation_insert_trigger
relation_delete_trigger_function
relation_delete_trigger
relation_update_trigger_function
relation_update_trigger

*/
begin;

-- these functions are created in meta_meta (so they can be discarded)
set search_path=meta_meta;

/******************************************************************************
component_statement()

For the supplied entity (e.g. `relation`, `column` etc., an entry in the
pg_entity table), and the supplied component (e.g. `type`, `type_constructor`,
`cast_to_json` etc.), generate the statement that creates said component for
said entity.

Usage:  Use component_statement() with exec() in a SQL query that queries
pg_entity and pg_component.

To generate all components:

```
select e.name as entity_name, c.name as component_name, exec(component_statement(e.name, c.name))
from pg_entity e, pg_entity_component c
order by e.name, c.position;
```
******************************************************************************/

create or replace function component_statement(entity text, component text) returns text as $$
declare
stmt text;
begin
    execute format('
    select %I(name, constructor_arg_names, constructor_arg_types)
    from meta_meta.pg_entity e
    where name=%L',
        'stmt_create_' || component,
        entity
    ) into stmt;
    return stmt;
end
$$ language plpgsql;


/*
 * generates a bunch of plpgsql snippets that are recurring patterns in the the code generators below
 */
create or replace function stmt_snippets(name text, constructor_arg_names text[], constructor_arg_types text[]) returns public.hstore as $$
declare
    arg_name text;
    result public.hstore;
    i integer := 1;

    -- snippets
    constructor_args text := '';           -- "schema_name text, relation_name text, name text"
    attributes text := '';                 -- "schema_name text, relation_name text, name text"
    arg_names text := '';                  -- "schema_name, relation_name, name"
    compare_to_jsonb text := 'select ';     -- "select (leftarg).schema_name = rightarg->>'schema_name' and (leftarg).name = rightarg->>'name'"
    constructor_args_from_jsonb text := ''; -- value->>'schema_name', value->>'name'
    meta_id_path text := name || '/';

begin
    foreach arg_name in array constructor_arg_names loop
        attributes :=       attributes                                  || format('%I %s', constructor_arg_names[i], constructor_arg_types[i]);
        constructor_args := constructor_args                            || format('%I %s', constructor_arg_names[i], constructor_arg_types[i]);
        arg_names :=        arg_names                                   || format('%I', constructor_arg_names[i]);
        meta_id_path :=     meta_id_path                                || format('%I', constructor_arg_names[i]);

		-- constructor args from json
		if constructor_arg_types[i] = 'text[]' then
			constructor_args_from_jsonb :=  constructor_args_from_jsonb ||
                format('(select array_agg(value) from jsonb_array_elements_text(value->%L))', constructor_arg_names[i]);
		else
			constructor_args_from_jsonb :=  constructor_args_from_jsonb ||
                format('value->>%L', constructor_arg_names[i]);
		end if;
        -- compare to jsonb
        if constructor_arg_types[i] = 'text[]' then
            compare_to_jsonb :=  compare_to_jsonb
                || format('to_jsonb((leftarg).%I) = rightarg->%L', constructor_arg_names[i], constructor_arg_names[i]);
        else
            compare_to_jsonb :=  compare_to_jsonb ||
                format('(leftarg).%I = rightarg->>%L', constructor_arg_names[i], constructor_arg_names[i]);
        end if;

        -- comma?
        if i < array_length(constructor_arg_names,1) then
            attributes := attributes || ',';
            constructor_args := constructor_args || ',';
            arg_names := arg_names || ',';
            compare_to_jsonb := compare_to_jsonb || ' and ';
            constructor_args_from_jsonb := constructor_args_from_jsonb || ', ';
            meta_id_path := meta_id_path || '/';
        end if;
        i := i+1;
        -- raise notice '    arg_names: %', arg_names;
    end loop;

    -- raise notice 'results:::::';
    -- raise notice 'attributes: %', attributes;
    -- raise notice 'constructor_args: %', constructor_args;
    -- raise notice 'compare_to_jsonb: %', compare_to_jsonb;
    result := format('constructor_args=>"%s",attributes=>"%s",arg_names=>"%s",compare_to_jsonb=>"%s",constructor_args_from_jsonb=>"%s",meta_id_path=>"%s"',
        constructor_args,
        attributes,
        arg_names,
        compare_to_jsonb,
        constructor_args_from_jsonb,
        meta_id_path
    )::public.hstore;
    -- raise notice 'result: %', result;
    return result;
end;
$$ language plpgsql;


/**********************************************************************************
create type meta2.relation_id as (schema_name text,name text);
**********************************************************************************/
create or replace function stmt_create_type (name text, constructor_arg_names text[], constructor_arg_types text[]) returns text as $$
declare
    stmt text := '';
    snippets public.hstore;
begin
    snippets := stmt_snippets(name, constructor_arg_names, constructor_arg_types);
    stmt := format('create type meta2.%I as (%s);', name || '_id', snippets['attributes']);
    return stmt;
end;
$$ language plpgsql;


/**********************************************************************************
Constructor

PostgreSQL composite types are instantiated via `row('public','my_table',
'id')::column_id`, but this isn't very pretty, so each meta-id also has a
constructor function whose arguments are the same as the arguments you would
pass to row().

Instead of:

select row('public','my_table','my_column')::meta.column_id;

This lets you do:

select meta.column_id('public','my_table','my_column');


Function output (for relation entity):
```
create or replace function meta2.meta_id(relation_id meta2.relation_id) returns meta2.meta_id as $_$
    select meta2.meta_id('relation/' || quote_ident(relation_id.schema_name) || '/' || quote_ident(relation_id.name));
$_$ language sql;
```
**********************************************************************************/
create or replace function stmt_create_meta_id_constructor (name text, constructor_arg_names text[], constructor_arg_types text[]) returns text as $$
declare
    stmt text := '';
    snippets public.hstore;
begin
    snippets := stmt_snippets(name, constructor_arg_names, constructor_arg_types);
    stmt := format('create function meta2.meta_id(%I meta2.%I) returns meta2.meta_id as $_$ select meta2.meta_id(%L); $_$ language sql;', name || '_id', name || '_id', name, snippets['meta_id_path']);
    return stmt;
end;
$$ language plpgsql;


/**********************************************************************************
create function meta2.relation_id(schema_name text,name text) returns meta2.relation_id as $_$
    select row(schema_name,name)::meta2.relation_id
$_$ language sql immutable;
**********************************************************************************/
create or replace function stmt_create_type_constructor_function (name text, constructor_arg_names text[], constructor_arg_types text[]) returns text as $$
declare
    stmt text := '';
    snippets public.hstore;
    i integer := 1;
begin
    snippets := stmt_snippets(name, constructor_arg_names, constructor_arg_types);
    stmt := format('create function meta2.%I(%s) returns meta2.%I as $_$ select row(%s)::meta2.%I $_$ language sql immutable;',
       name || '_id',
       snippets['attributes'],
       name || '_id',
       snippets['arg_names'],
       name || '_id'
    );
    return stmt;
end;
$$ language plpgsql;

/**********************************************************************************
create function meta2.eq(leftarg meta2.relation_id, rightarg jsonb) returns boolean as
    $_$select (leftarg).schema_name = rightarg->>'schema_name' and (leftarg).name = rightarg->>'name'
$_$ language sql;
**********************************************************************************/
create or replace function stmt_create_type_to_jsonb_comparator_function (name text, constructor_arg_names text[], constructor_arg_types text[]) returns text as $$
declare
    stmt text := '';
    snippets public.hstore;
    i integer := 1;
begin
    snippets := stmt_snippets(name, constructor_arg_names, constructor_arg_types);
    stmt := format('create function meta2.eq(leftarg meta2.%I, rightarg jsonb) returns boolean as $_$%s$_$ language sql;',
        name || '_id',
        snippets['compare_to_jsonb']
    );
    return stmt;
end;
$$ language plpgsql;


/**********************************************************************************
create operator pg_catalog.= (leftarg = meta2.relation_id, rightarg = jsonb, procedure = meta2.eq);
**********************************************************************************/
create or replace function stmt_create_type_to_jsonb_comparator_op (name text, constructor_arg_names text[], constructor_arg_types text[]) returns text as $$
declare
    stmt text := '';
    snippets public.hstore;
    i integer := 1;
begin
    snippets := stmt_snippets(name, constructor_arg_names, constructor_arg_types);
    stmt := format('create operator pg_catalog.= (leftarg = meta2.%I, rightarg = jsonb, procedure = meta2.eq);',
        name || '_id'
    );
    return stmt;
end;
$$ language plpgsql;


/**********************************************************************************
create function meta2.relation_id(value jsonb) returns meta2.relation_id as $_$
select meta2.relation_id(value->>'schema_name', value->>'name')
$_$ immutable language sql;
**********************************************************************************/
create or replace function stmt_create_type_to_jsonb_type_constructor_function (name text, constructor_arg_names text[], constructor_arg_types text[]) returns text as $$
declare
    stmt text := '';
    snippets public.hstore;
    i integer := 1;
begin
    snippets := stmt_snippets(name, constructor_arg_names, constructor_arg_types);
    stmt := format('create function meta2.%I(value jsonb) returns meta2.%I as $_$select meta2.%I(%s) $_$ immutable language sql;',
        name || '_id',
        name || '_id',
        name || '_id',
        snippets['constructor_args_from_jsonb']
    );
    return stmt;
end;
$$ language plpgsql;


/**********************************************************************************
create cast (jsonb as meta2.relation_id) with function meta2.relation_id(jsonb) as assignment;
**********************************************************************************/
create or replace function stmt_create_type_to_jsonb_cast (name text, constructor_arg_names text[], constructor_arg_types text[]) returns text as $$
declare
    stmt text := '';
    snippets public.hstore;
    i integer := 1;
begin
    snippets := stmt_snippets(name, constructor_arg_names, constructor_arg_types);
    stmt := format('create cast (jsonb as meta2.%I) with function meta2.%I(jsonb) as assignment;',
        name || '_id',
        name || '_id'
    );
    return stmt;
end;
$$ language plpgsql;


commit;
