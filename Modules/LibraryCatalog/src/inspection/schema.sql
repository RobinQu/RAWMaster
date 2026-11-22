CREATE TABLE lc_inspect_imports(
    revision_id INTEGER PRIMARY KEY, work_id TEXT NOT NULL, source_catalog TEXT NOT NULL, source_object TEXT NOT NULL,
    source_revision TEXT NOT NULL, fields_json TEXT NOT NULL CHECK(json_valid(fields_json)),
    UNIQUE(work_id,source_catalog,source_object,source_revision)
);
CREATE INDEX lc_inspect_import_history ON lc_inspect_imports(work_id,source_catalog,source_object,revision_id);
CREATE TABLE lc_inspect_manual(
    work_id TEXT NOT NULL, field TEXT NOT NULL, value_json TEXT NOT NULL CHECK(json_valid(value_json)), command_id TEXT NOT NULL,
    PRIMARY KEY(work_id,field)
);
CREATE TABLE lc_inspect_undo(
    command_id TEXT NOT NULL, work_id TEXT NOT NULL, field TEXT NOT NULL, old_value TEXT, old_command TEXT, undone INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(command_id,work_id,field)
);
CREATE VIEW lc_inspect_import_effective(work_id,field,value_json,source_catalog,source_object,source_revision) AS
    SELECT i.work_id,k.key,json_quote(k.value),i.source_catalog,i.source_object,i.source_revision FROM lc_inspect_imports i,json_each(i.fields_json) k
    WHERE NOT EXISTS(SELECT 1 FROM lc_inspect_imports n WHERE n.work_id=i.work_id AND n.source_catalog=i.source_catalog
        AND n.source_object=i.source_object AND n.revision_id>i.revision_id)
    AND NOT EXISTS(SELECT 1 FROM lc_inspect_imports n,json_each(n.fields_json) nk WHERE n.work_id=i.work_id AND n.revision_id>i.revision_id
        AND nk.key=k.key AND NOT EXISTS(SELECT 1 FROM lc_inspect_imports latest WHERE latest.work_id=n.work_id
            AND latest.source_catalog=n.source_catalog AND latest.source_object=n.source_object AND latest.revision_id>n.revision_id));
CREATE VIEW lc_inspect_work_effective(work_id,field,value_json,origin) AS
    SELECT work_id,field,value_json,'manual' FROM lc_inspect_manual
    UNION ALL SELECT i.work_id,i.field,i.value_json,'lightroom' FROM lc_inspect_import_effective i
    WHERE NOT EXISTS(SELECT 1 FROM lc_inspect_manual m WHERE m.work_id=i.work_id AND m.field=i.field);
CREATE TABLE lc_inspect_files(
    file_id TEXT NOT NULL REFERENCES lc_files(file_id), content_id TEXT NOT NULL REFERENCES lc_contents(content_id),
    fields_json TEXT NOT NULL CHECK(json_valid(fields_json)), af_json TEXT NOT NULL CHECK(json_valid(af_json)), extractor TEXT NOT NULL,
    PRIMARY KEY(file_id,content_id)
);
CREATE TABLE lc_inspect_samples(
    file_id TEXT NOT NULL REFERENCES lc_files(file_id), content_id TEXT NOT NULL REFERENCES lc_contents(content_id), sample_id TEXT NOT NULL,
    kind TEXT NOT NULL, data TEXT NOT NULL CHECK(json_valid(data)), PRIMARY KEY(file_id,content_id,sample_id)
);
CREATE TABLE lc_inspect_focus(
    file_id TEXT NOT NULL REFERENCES lc_files(file_id), content_id TEXT NOT NULL REFERENCES lc_contents(content_id),
    machine TEXT, manual TEXT, evidence TEXT CHECK(evidence IS NULL OR json_valid(evidence)), manual_command TEXT,
    PRIMARY KEY(file_id,content_id)
);
CREATE VIEW lc_inspect_file_effective(file_id,content_id,field,value_json,origin) AS
    SELECT f.file_id,f.content_id,k.key,json_quote(k.value),'embedded' FROM lc_inspect_files f,json_each(f.fields_json) k
    UNION ALL SELECT file_id,content_id,'focusMachine',json_quote(machine),'analysis' FROM lc_inspect_focus WHERE machine IS NOT NULL
    UNION ALL SELECT file_id,content_id,'focusManual',json_quote(manual),'manual' FROM lc_inspect_focus WHERE manual IS NOT NULL
    UNION ALL SELECT file_id,content_id,'focusEffective',json_quote(coalesce(manual,machine)),CASE WHEN manual IS NULL THEN 'analysis' ELSE 'manual' END
        FROM lc_inspect_focus WHERE coalesce(manual,machine) IS NOT NULL;
