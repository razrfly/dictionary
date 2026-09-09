defmodule DevilsDictionary.Repo.Migrations.NormalizePronunciationObservations do
  use Ecto.Migration

  def up do
    execute("""
    CREATE FUNCTION dd_normalize_pronunciations() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF jsonb_typeof(NEW.pronunciations->'items') = 'array' THEN
        SELECT CASE WHEN count(*)=0 THEN '{}'::jsonb
          ELSE jsonb_build_object('items',jsonb_agg(v ORDER BY v)) END
        INTO NEW.pronunciations
        FROM (SELECT DISTINCT v FROM jsonb_array_elements(NEW.pronunciations->'items') v) items;
      END IF;
      RETURN NEW;
    END $$;
    """)

    execute("""
    CREATE TRIGGER normalize_pronunciations BEFORE INSERT OR UPDATE OF pronunciations ON lexemes
      FOR EACH ROW EXECUTE FUNCTION dd_normalize_pronunciations();
    """)
  end

  def down do
    execute("DROP TRIGGER normalize_pronunciations ON lexemes")
    execute("DROP FUNCTION dd_normalize_pronunciations()")
  end
end
