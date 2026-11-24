CREATE TABLE lc_workbench_names (
    item_key TEXT PRIMARY KEY NOT NULL,
    writer_id TEXT NOT NULL,
    directory_scope TEXT NOT NULL,
    normalized_name TEXT NOT NULL,
    volume_uuid TEXT
) WITHOUT ROWID;
CREATE INDEX lc_workbench_name_lookup
    ON lc_workbench_names(writer_id,directory_scope,normalized_name);

-- An old SQLite handle can outlive Queue::open's format check. A workbench
-- publication re-reads the versioned control under the same write lock.
CREATE TRIGGER lc_workbench_writer_insert
BEFORE INSERT ON lc_meta
WHEN NEW.key GLOB 'wb032.name.v1/*'
    OR (NEW.key GLOB 'wb032.control.v1/*' AND NOT (
        CASE WHEN json_valid(NEW.value) THEN COALESCE(
            json_type(NEW.value,'$.schema')='integer' AND json_extract(NEW.value,'$.schema')=2,0)
        ELSE 0 END))
BEGIN SELECT RAISE(ABORT,'workbench writer requires control schema 2'); END;

CREATE TRIGGER lc_workbench_writer_update
BEFORE UPDATE OF key,value ON lc_meta
WHEN NEW.key GLOB 'wb032.name.v1/*'
    OR (NEW.key GLOB 'wb032.control.v1/*' AND NOT (
        CASE WHEN json_valid(NEW.value) THEN COALESCE(
            json_type(NEW.value,'$.schema')='integer' AND json_extract(NEW.value,'$.schema')=2,0)
        ELSE 0 END))
BEGIN SELECT RAISE(ABORT,'workbench writer requires control schema 2'); END;
