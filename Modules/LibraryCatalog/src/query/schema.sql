CREATE TABLE generations (
    gen INTEGER PRIMARY KEY AUTOINCREMENT,
    token TEXT NOT NULL UNIQUE DEFAULT (lower(hex(randomblob(16)))),
    library TEXT NOT NULL, source_stamp TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('building','active','obsolete')),
    watermark INTEGER NOT NULL, after_row INTEGER, scanned INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX one_active ON generations(state) WHERE state='active';
CREATE UNIQUE INDEX one_build ON generations(state) WHERE state='building';

CREATE TABLE documents (
    doc INTEGER PRIMARY KEY, gen INTEGER NOT NULL REFERENCES generations(gen),
    asset_id TEXT NOT NULL, file_id TEXT NOT NULL, capture_id TEXT NOT NULL, project_id TEXT NOT NULL,
    session_id TEXT NOT NULL, session_ord INTEGER NOT NULL, asset_ord INTEGER NOT NULL,
    filename TEXT NOT NULL, name_key TEXT NOT NULL, relative_path TEXT NOT NULL, path_tie TEXT NOT NULL,
    camera TEXT, camera_key TEXT, captured REAL, missing_time INTEGER NOT NULL,
    time_asc REAL NOT NULL, time_desc REAL NOT NULL, rating INTEGER NOT NULL, rating_desc INTEGER NOT NULL,
    decision TEXT NOT NULL, availability TEXT NOT NULL, color_label TEXT, reviewed INTEGER NOT NULL,
    format TEXT NOT NULL, sequence_only INTEGER NOT NULL,
    body TEXT NOT NULL, record TEXT NOT NULL, role TEXT NOT NULL,
    UNIQUE(gen,project_id,file_id)
);
CREATE INDEX docs_asset ON documents(gen,asset_id);
CREATE INDEX docs_file ON documents(gen,file_id,asset_id,project_id);
CREATE INDEX docs_capture ON documents(gen,capture_id,asset_id,project_id,file_id);
CREATE INDEX docs_camera ON documents(gen,camera_key,missing_time,time_desc);
CREATE INDEX docs_rating ON documents(gen,rating);
CREATE INDEX docs_session ON documents(gen,session_id);
CREATE TABLE doc_tags (
    doc INTEGER NOT NULL REFERENCES documents(doc) ON DELETE CASCADE,
    key TEXT NOT NULL, display TEXT NOT NULL, PRIMARY KEY(doc,key)
) WITHOUT ROWID;
CREATE INDEX tags_lookup ON doc_tags(key,doc);
CREATE TABLE doc_groups (
    doc INTEGER NOT NULL REFERENCES documents(doc) ON DELETE CASCADE,
    group_id TEXT NOT NULL, position INTEGER NOT NULL, PRIMARY KEY(doc,group_id)
) WITHOUT ROWID;
CREATE INDEX groups_lookup ON doc_groups(group_id,position,doc);

-- Maintain both whole-library and per-project exact unfiltered totals. Removing
-- an occurrence only retires a logical file/capture when its last occurrence goes.
CREATE TABLE object_refs (
    gen INTEGER NOT NULL, scope TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL,
    n INTEGER NOT NULL, PRIMARY KEY(gen,scope,kind,id)
) WITHOUT ROWID;
CREATE TABLE scope_counts (
    gen INTEGER NOT NULL, scope TEXT NOT NULL, files INTEGER NOT NULL, captures INTEGER NOT NULL,
    PRIMARY KEY(gen,scope)
) WITHOUT ROWID;
CREATE TRIGGER count_first AFTER INSERT ON object_refs BEGIN
    INSERT INTO scope_counts VALUES(new.gen,new.scope,new.kind='file',new.kind='capture')
    ON CONFLICT(gen,scope) DO UPDATE SET files=files+excluded.files,captures=captures+excluded.captures;
END;
CREATE TRIGGER count_last AFTER DELETE ON object_refs BEGIN
    UPDATE scope_counts SET files=files-(old.kind='file'),captures=captures-(old.kind='capture')
    WHERE gen=old.gen AND scope=old.scope;
END;
CREATE TRIGGER document_added AFTER INSERT ON documents BEGIN
    INSERT INTO object_refs VALUES (new.gen,'L','file',new.file_id,1),
        (new.gen,'L','capture',new.capture_id,1),
        (new.gen,'P'||new.project_id,'file',new.file_id,1),
        (new.gen,'P'||new.project_id,'capture',new.capture_id,1)
    ON CONFLICT(gen,scope,kind,id) DO UPDATE SET n=n+1;
END;
CREATE TRIGGER document_removed AFTER DELETE ON documents BEGIN
    UPDATE object_refs SET n=n-1 WHERE gen=old.gen AND scope IN ('L','P'||old.project_id)
        AND ((kind='file' AND id=old.file_id) OR (kind='capture' AND id=old.capture_id));
    DELETE FROM object_refs WHERE gen=old.gen AND scope IN ('L','P'||old.project_id) AND n=0
        AND ((kind='file' AND id=old.file_id) OR (kind='capture' AND id=old.capture_id));
END;
