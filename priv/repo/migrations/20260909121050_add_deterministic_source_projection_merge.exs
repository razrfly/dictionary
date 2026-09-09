defmodule DevilsDictionary.Repo.Migrations.AddDeterministicSourceProjectionMerge do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION dd_merge_projected_metadata(previous jsonb, incoming jsonb)
    RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
    DECLARE result jsonb := previous; owners jsonb := COALESCE(previous->'_projection_owners','{}');
      owner jsonb := incoming->'_projection_origin'; k text; v jsonb;
    BEGIN
      IF owner IS NULL THEN RETURN previous || incoming; END IF;
      FOR k,v IN SELECT key,value FROM jsonb_each(owners) LOOP
        IF v = owner AND NOT incoming ? k THEN
          result := result - k; owners := owners - k;
        END IF;
      END LOOP;
      FOR k,v IN SELECT key,value FROM jsonb_each(incoming - ARRAY['_projection_origin','_projection_owners']) LOOP
        IF NOT owners ? k OR ((owner->>0)::int, (owner->>1) COLLATE "C") <= (((owners->k)->>0)::int, ((owners->k)->>1) COLLATE "C") THEN
          result := jsonb_set(result, ARRAY[k], v);
          owners := jsonb_set(owners, ARRAY[k], owner);
        END IF;
      END LOOP;
      IF previous->'_projection_origin' IS NULL OR ((owner->>0)::int, (owner->>1) COLLATE "C") < (((previous->'_projection_origin')->>0)::int, ((previous->'_projection_origin')->>1) COLLATE "C") THEN
        result := jsonb_set(result, '{_projection_origin}', owner);
      END IF;
      RETURN jsonb_set(result, '{_projection_owners}', owners);
    END $$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION dd_merge_lexeme_metadata(previous jsonb, incoming jsonb)
    RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
    DECLARE result jsonb := previous || incoming; categories jsonb;
    BEGIN
      IF previous ? 'wikt_categories' OR incoming ? 'wikt_categories' THEN
        SELECT COALESCE(jsonb_agg(v ORDER BY v COLLATE "C"),'[]'::jsonb) INTO categories
        FROM (SELECT DISTINCT v FROM jsonb_array_elements_text(COALESCE(previous->'wikt_categories','[]') || COALESCE(incoming->'wikt_categories','[]')) v) combined;
        result := jsonb_set(result,'{wikt_categories}',categories);
      END IF;
      IF previous ? 'form_of' AND incoming ? 'form_of' THEN
        result := jsonb_set(result,'{form_of}',to_jsonb((previous->>'form_of')::boolean AND (incoming->>'form_of')::boolean));
      END IF;
      IF previous->>'_etymology_owner' IS NOT NULL AND incoming->>'_etymology_owner' IS NOT NULL
        AND (previous->>'_etymology_owner') COLLATE "C" < (incoming->>'_etymology_owner') COLLATE "C" THEN
        result := jsonb_set(result,'{_etymology_owner}',previous->'_etymology_owner');
      END IF;
      RETURN result;
    END $$;
    """)
  end

  def down do
    execute("DROP FUNCTION dd_merge_lexeme_metadata(jsonb,jsonb)")
    execute("DROP FUNCTION dd_merge_projected_metadata(jsonb,jsonb)")
  end
end
